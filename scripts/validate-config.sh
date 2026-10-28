#!/usr/bin/env bash
# Valida la configuración del repo. Lo corre el job `tests` de .github/workflows/testing.yml
# y sirve igual en local: bash scripts/validate-config.sh
#
# Este repo es infraestructura (docker compose + configs de Alloy/Loki/Grafana), no una app:
# lo que se puede romper es un YAML mal escrito o un compose inválido.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
fail=0

step() { printf '\n▶ %s\n' "$*"; }

step "Sintaxis YAML"
if ! python3 -c "import yaml" 2>/dev/null; then
  echo "  ⚠ falta PyYAML, se saltea (instalalo con: python3 -m pip install pyyaml)"
else
  python3 <<'PYCHK' || fail=1
import subprocess, sys, yaml

out = subprocess.run(["git", "ls-files", "-z", "*.yml", "*.yaml"],
                     capture_output=True, text=True, check=True).stdout
paths = [p for p in out.split("\0") if p]
if not paths:
    print("  (no hay archivos YAML trackeados)")
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

step "docker compose"
composes="$(git ls-files 'docker-compose*.yml' 'docker-compose*.yaml' 'compose*.yml' 'compose*.yaml')"
if [ -z "$composes" ]; then
  echo "  (todavía no hay compose en el repo)"
elif ! command -v docker >/dev/null; then
  echo "  ⚠ docker no está instalado, se saltea la validación del compose"
else
  while IFS= read -r f; do
    if docker compose -f "$f" config -q; then
      echo "  ok $f"
    else
      echo "  x $f"
      fail=1
    fi
  done <<< "$composes"
fi

# PENDIENTE: cuando existan las configs, agregar acá su validación nativa.
#   Loki:  docker run --rm -v "$PWD:/w" grafana/loki:<ver> -config.file=/w/loki/loki.yml -verify-config
#   Alloy: docker run --rm -v "$PWD:/w" grafana/alloy:<ver> fmt --verify /w/alloy/config.alloy
# Antes de ponerlas en CI, probar el comando exacto contra la versión que use el compose.

printf '\n'
if [ "$fail" -ne 0 ]; then
  echo "✖ La validación falló."
  exit 1
fi
echo "✔ Configuración válida."
