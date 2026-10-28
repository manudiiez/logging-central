#!/usr/bin/env bash
# Valida la configuración del stack. Lo corre el job `tests` de CI y sirve igual en
# local: bash scripts/validate-config.sh
#
# Este repo es infraestructura: lo que se puede romper es un YAML mal escrito, un
# compose inválido o una config que Alloy o Loki rechazan al arrancar. Cada validador
# usa la misma versión de imagen que el Dockerfile correspondiente, así que no hay
# deriva entre lo que se valida y lo que corre.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
fail=0

step() { printf '\n> %s\n' "$*"; }
ok()   { printf '  ok %s\n' "$*"; }
bad()  { printf '  x %s\n' "$*"; fail=1; }
skip() { printf '  - %s\n' "$*"; }

# Toma la imagen base del Dockerfile para no duplicar la versión acá.
imagen_de() { sed -n 's/^FROM  *//p' "$1" | head -1; }

step "Sintaxis YAML"
if ! python3 -c "import yaml" 2>/dev/null; then
  skip "falta PyYAML, se saltea (instalalo con: python3 -m pip install pyyaml)"
else
  python3 <<'PYCHK' || fail=1
import subprocess, sys, yaml

out = subprocess.run(["git", "ls-files", "-z", "*.yml", "*.yaml"],
                     capture_output=True, text=True, check=True).stdout
paths = [p for p in out.split("\0") if p]
if not paths:
    print("  - no hay archivos YAML trackeados")
    sys.exit(0)

bad = 0
for path in paths:
    try:
        with open(path) as fh:
            list(yaml.safe_load_all(fh))
    except yaml.YAMLError as exc:
        print(f"  x {path}: {exc}")
        bad = 1
    else:
        print(f"  ok {path}")
sys.exit(bad)
PYCHK
fi

step "Dashboards de Grafana (JSON y campos mínimos)"
if [ ! -d grafana/dashboards ]; then
  skip "no hay grafana/dashboards"
else
  python3 <<'PYDASH' || fail=1
import json, pathlib, sys

bad = 0
archivos = sorted(pathlib.Path("grafana/dashboards").glob("*.json"))
if not archivos:
    print("  - no hay dashboards")
for f in archivos:
    try:
        d = json.loads(f.read_text())
    except json.JSONDecodeError as exc:
        print(f"  x {f}: JSON inválido: {exc}")
        bad = 1
        continue
    faltan = [k for k in ("uid", "title", "panels") if k not in d]
    if faltan:
        print(f"  x {f}: faltan claves {faltan}")
        bad = 1
        continue
    sin_target = [p.get("title", p.get("id")) for p in d["panels"] if not p.get("targets")]
    if sin_target:
        print(f"  x {f}: paneles sin consulta: {sin_target}")
        bad = 1
        continue
    print(f"  ok {f} ({len(d['panels'])} paneles)")
sys.exit(bad)
PYDASH
fi

if ! command -v docker >/dev/null || ! docker info >/dev/null 2>&1; then
  step "Validaciones que necesitan Docker"
  skip "docker no disponible, se saltean compose, Alloy y Loki"
  printf '\n'
  [ "$fail" -ne 0 ] && { echo "x La validación falló."; exit 1; }
  echo "ok Configuración válida (parcial: sin Docker)."
  exit 0
fi

step "docker compose"
# Los dos compose exigen variables a propósito (GRAFANA_ADMIN_PASSWORD y, en
# producción, STACK_VERSION). Se les pasan valores ficticios y `--env-file /dev/null`
# para validar solo la estructura: así el resultado no depende de que quien lo corra
# tenga un .env, y en CI da lo mismo que en local.
compose_vars() {
  env STACK_VERSION=v0.0.0 ENVIRONMENT=ci GRAFANA_ADMIN_PASSWORD=ci GRAFANA_ROOT_URL=http://ci "$@"
}
for f in docker-compose.yml docker-compose.production.yml; do
  if compose_vars docker compose -f "$f" --env-file /dev/null config -q; then
    ok "$f"
  else
    bad "$f"
  fi
done

step "Configuración de Alloy"
if [ -f alloy/config.alloy ]; then
  img="$(imagen_de alloy/Dockerfile)"
  if docker run --rm -e SERVICE_NAMESPACE=ci -e ENVIRONMENT=ci \
       -v "$PWD/alloy:/w:ro" "$img" validate /w/config.alloy; then
    ok "alloy validate ($img)"
  else
    bad "alloy validate ($img)"
  fi
else
  skip "no hay alloy/config.alloy"
fi

step "Configuración de Loki"
if [ -f loki/loki.yml ]; then
  img="$(imagen_de loki/Dockerfile)"
  if docker run --rm -v "$PWD/loki:/w:ro" "$img" -config.file=/w/loki.yml -verify-config; then
    ok "loki -verify-config ($img)"
  else
    bad "loki -verify-config ($img)"
  fi
else
  skip "no hay loki/loki.yml"
fi

printf '\n'
if [ "$fail" -ne 0 ]; then
  echo "x La validación falló."
  exit 1
fi
echo "ok Configuración válida."
