#!/usr/bin/env bash
# Verifica de punta a punta que el colector funciona: emite logs de prueba desde un
# contenedor, espera a que lleguen a Loki y comprueba que los labels y la structured
# metadata son los que define el contrato.
#
# Uso: bash scripts/smoke-test.sh      (el stack tiene que estar levantado)
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

LOKI="${LOKI_URL:-http://localhost:${LOKI_PORT:-3100}}"
NS="${SERVICE_NAMESPACE:-nazar}"
ENV_NAME="${ENVIRONMENT:-development}"
# Cada corrida usa nombres propios: así las líneas de una corrida anterior, que siguen
# dentro de la ventana de consulta, no se cuentan como si fueran de esta.
RUN="$(date +%s)"
SVC="smoke-test-$RUN"
RID="smoke-$RUN"
CONTAINER="logging-central-smoke-$RUN"

cleanup() {
  # xargs -r no existe en macOS, de ahí el `while read`.
  docker ps -aq --filter "name=^logging-central-smoke-" | while IFS= read -r c; do
    [ -n "$c" ] && docker rm -f "$c" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

step() { printf '\n> %s\n' "$*"; }
fail() { printf '  x %s\n' "$*"; FAILED=1; }
ok()   { printf '  ok %s\n' "$*"; }
FAILED=0

query() {
  curl -sG "$LOKI/loki/api/v1/query_range" \
    --data-urlencode "query=$1" \
    --data-urlencode "limit=100" \
    --data-urlencode "start=$(( $(date +%s) - 600 ))000000000"
}
count_lines() {
  python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); raise SystemExit
print(sum(len(r["values"]) for r in d.get("data", {}).get("result", [])))'
}

step "Esperar a que Loki esté listo (hasta 90s)"
# `docker compose up -d` devuelve cuando los contenedores arrancaron, no cuando Loki
# terminó de inicializar: tarda unos 15s más. Sin esta espera el script falla si se lo
# invoca inmediatamente después de levantar el stack, que es justo lo que hace CI.
deadline=$(( $(date +%s) + 90 ))
until curl -sf "$LOKI/ready" >/dev/null 2>&1; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "  x $LOKI/ready no responde después de 90s."
    echo "    ¿Está levantado el stack? docker compose up -d"
    echo "    Si lo está: docker compose logs loki"
    exit 1
  fi
  sleep 2
done
ok "$LOKI/ready"

step "Emitir logs de prueba (request.id=$RID)"
cleanup
# Seis líneas que cumplen el contrato y una que no es JSON, para comprobar que una
# línea mal formada no rompe el pipeline y llega igual.
docker run -d --name "$CONTAINER" --label logging=true alpine:3 sh -c "
  for i in 1 2 3 4 5; do
    printf '{\"timestamp\":\"%s\",\"level\":\"info\",\"message\":\"Request completado\",\"event.name\":\"http.request_completed\",\"logger\":\"smoke\",\"service.name\":\"$SVC\",\"service.namespace\":\"$NS\",\"service.version\":\"0.0.0-smoke\",\"deployment.environment.name\":\"$ENV_NAME\",\"request.id\":\"$RID\",\"http.request.method\":\"GET\",\"http.route\":\"/health\",\"http.response.status_code\":200,\"duration_ms\":12.5}\n' \"\$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\";
  done
  printf '{\"timestamp\":\"%s\",\"level\":\"error\",\"message\":\"Request completado\",\"event.name\":\"http.request_completed\",\"logger\":\"smoke\",\"service.name\":\"$SVC\",\"service.namespace\":\"$NS\",\"service.version\":\"0.0.0-smoke\",\"deployment.environment.name\":\"$ENV_NAME\",\"request.id\":\"$RID\",\"http.response.status_code\":500,\"error.type\":\"SMOKE_TEST_ERROR\"}\n' \"\$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\";
  echo 'esta linea no es json y tiene que llegar igual';
  sleep 180
" >/dev/null
ok "contenedor $CONTAINER emitiendo"

step "Esperar a que Loki reciba el stream (hasta 60s)"
deadline=$(( $(date +%s) + 60 ))
total=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  total="$(query "{service_name=\"$SVC\"} | request_id=\"$RID\"" | count_lines)"
  [ "$total" -ge 6 ] && break
  sleep 3
done
if [ "$total" -ge 6 ]; then
  ok "$total líneas JSON recibidas con service_name=$SVC"
else
  fail "solo llegaron $total líneas de 6. Revisá: docker compose logs alloy"
fi

step "Labels indexados"
labels="$(curl -sf "$LOKI/loki/api/v1/labels" | python3 -c 'import json,sys; print(" ".join(sorted(json.load(sys.stdin).get("data") or [])))')"
echo "  labels en Loki: $labels"
for l in service_name service_namespace environment container; do
  case " $labels " in *" $l "*) ok "$l presente" ;; *) fail "falta el label $l" ;; esac
done
# Lo que NO tiene que estar indexado: alta cardinalidad, o filtrable sin índice.
for l in request_id user_id level event_name trace_id; do
  case " $labels " in
    *" $l "*) fail "$l está como LABEL y no debería" ;;
    *) ok "$l no es label, como corresponde" ;;
  esac
done

step "Valores de los labels del servicio de prueba"
stream_json="$(query "{service_name=\"$SVC\"}")"
got_ns="$(printf '%s' "$stream_json" | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["stream"].get("service_namespace","") if r else "")')"
got_env="$(printf '%s' "$stream_json" | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["stream"].get("environment","") if r else "")')"
[ "$got_ns" = "$NS" ] && ok "service_namespace=$got_ns" || fail "service_namespace=$got_ns (esperado $NS)"
[ "$got_env" = "$ENV_NAME" ] && ok "environment=$got_env" || fail "environment=$got_env (esperado $ENV_NAME)"

step "Filtros por structured metadata"
errs="$(query "{service_name=\"$SVC\"} | level=\"error\"" | count_lines)"
[ "$errs" = "1" ] && ok "| level=\"error\" devuelve 1 línea" || fail "| level=\"error\" devolvió $errs, esperado 1"

byrid="$(query "{service_name=\"$SVC\"} | request_id=\"$RID\"" | count_lines)"
[ "$byrid" -ge 6 ] && ok "| request_id=\"$RID\" devuelve $byrid líneas" || fail "| request_id devolvió $byrid, esperado 6 o más"

errtype="$(query "{service_name=\"$SVC\"} | error_type=\"SMOKE_TEST_ERROR\"" | count_lines)"
[ "$errtype" = "1" ] && ok "| error_type=\"SMOKE_TEST_ERROR\" devuelve 1 línea" || fail "| error_type devolvió $errtype, esperado 1"

step "El timestamp es el de la app, no el que le puso Docker"
# Se compara el timestamp que indexó Loki, truncado a milisegundos, contra el campo
# `timestamp` de la propia línea. No se exige igualdad exacta al nanosegundo: Loki
# agrega un offset de pocos ns para desempatar líneas con el mismo timestamp.
ts_ok="$(query "{service_name=\"$SVC\"}" | python3 -c '
import json, sys, datetime
r = json.load(sys.stdin)["data"]["result"]
comparadas = 0
for st in r:
    for ns, line in st["values"]:
        try:
            app = json.loads(line)["timestamp"]
        except Exception:
            continue
        esperado = round(datetime.datetime.strptime(app, "%Y-%m-%dT%H:%M:%S.%fZ")
                         .replace(tzinfo=datetime.timezone.utc).timestamp() * 1000)
        if int(ns) // 1_000_000 != esperado:
            print("no"); raise SystemExit
        comparadas += 1
print("si" if comparadas else "no")')"
[ "$ts_ok" = "si" ] && ok "stage.timestamp usa el campo timestamp del log" || fail "los timestamps no vienen del log (revisá stage.timestamp)"

step "La línea cruda llega intacta"
raw_ok="$(query "{service_name=\"$SVC\"} | level=\"error\"" | python3 -c '
import json,sys
r = json.load(sys.stdin)["data"]["result"]
line = r[0]["values"][0][1] if r and r[0]["values"] else ""
try:
    d = json.loads(line)
except Exception:
    print("no"); raise SystemExit
print("si" if d.get("error.type") == "SMOKE_TEST_ERROR" and "http.response.status_code" in d else "no")')"
[ "$raw_ok" = "si" ] && ok "el JSON original se conserva completo" || fail "la línea no conserva el JSON original"

step "Una línea que no es JSON llega igual, con el service_name de fallback"
# Al no poder parsearla, el stage.json no extrae nada y el label service_name queda
# con el valor que puso el relabeling: el nombre del contenedor. Así los contenedores
# que no siguen el contrato (postgres, redis) también se recogen.
nojson="$(query "{container=\"$CONTAINER\"} |= \"no es json\"" | count_lines)"
[ "$nojson" = "1" ] && ok "una línea mal formada no rompe el pipeline y llega igual" || fail "la línea no-JSON no llegó (devolvió $nojson)"

fallback="$(query "{service_name=\"$CONTAINER\"}" | count_lines)"
[ "$fallback" -ge 1 ] && ok "quedó bajo service_name=$CONTAINER (fallback del relabeling)" || fail "no se aplicó el fallback de service_name"

printf '\n'
if [ "$FAILED" -ne 0 ]; then
  echo "x El smoke test falló."
  exit 1
fi
echo "ok Colector funcionando de punta a punta."
