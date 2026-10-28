# logging-central

Colector centralizado de logs: recoge el stdout de los contenedores de todas las apps y lo deja
consultable en un solo lugar.

```
contenedores de cada app ──stdout JSON──▶ Alloy ──push──▶ Loki ──consulta──▶ Grafana
                              (socket de Docker)
```

Es un repo de **infraestructura**: lo que versiona son un `docker compose` y las configuraciones de
los tres servicios, horneadas en imágenes propias derivadas de las oficiales de Grafana.

## Empezar

```bash
cp .env.example .env          # y poné una GRAFANA_ADMIN_PASSWORD
docker compose up -d --build
bash scripts/smoke-test.sh    # verifica la ingesta de punta a punta
```

Grafana en http://localhost:3000, con el dashboard "Logs — vista general" ya provisionado.

## Sumar una app

Que escriba JSON a stdout y que su servicio lleve el label `logging: "true"`. Nada más: no hay
shipper ni SDK que instalar. El detalle está en [`docs/colector.md`](docs/colector.md).

## Estructura

| Carpeta | Qué hay |
|---|---|
| `alloy/` | Config de Grafana Alloy: descubrimiento de contenedores, parseo del JSON, labels. |
| `loki/` | Config de Loki: almacenamiento, esquema, retención y límites. |
| `grafana/` | Datasource y dashboards provisionados por archivo. |
| `scripts/` | `validate-config.sh` (lo que corre CI) y `smoke-test.sh` (verificación de punta a punta). |
| `docs/` | [`colector.md`](docs/colector.md): cómo funciona, consultas, retención, deploy y diagnóstico. |

## Deploy

Las tres imágenes se publican en GHCR por tag de versión. En el VPS se usa
`docker-compose.production.yml` y el deploy —y el rollback— es cambiar `STACK_VERSION`.
Ver [`docs/colector.md`](docs/colector.md#deploy-en-el-vps).

## Contribuir

Ramas `develop` → `testing` → `main`, Conventional Commits y PRs: ver el bloque de flujo en
[`CLAUDE.md`](CLAUDE.md) o la skill `.claude/skills/flujo-github/`.
