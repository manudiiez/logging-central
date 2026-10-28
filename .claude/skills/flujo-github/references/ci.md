# CI: workflows de GitHub Actions

Tres workflows, uno por evento del flujo:

| Archivo | Evento | Qué hace |
|---|---|---|
| `pr-checks.yml` | PR hacia `develop`, `testing` o `main` | `pr-title`: valida que el título cumpla Conventional Commits. `branch-policy`: valida que el PR venga de la rama correcta. Los dos son checks requeridos por los rulesets. |
| `testing.yml` | push a `testing`, que solo ocurre al mergear un PR | `tests` → si pasan, `image`: publica `ghcr.io/<owner>/<repo>:testing` y `:sha-<commit>` |
| `release.yml` | push de un tag `vX.Y.Z` | Verifica que el tag apunte a un commit de `main` → publica `:vX.Y.Z` y `:sha-<commit>` |

Un push o merge a `develop` o a `main` **no construye imágenes**.

## Política de ramas (`branch-policy`)

| Base | Cabeceras permitidas |
|---|---|
| `develop` | `feat/*`, `fix/*`, `perf/*`, `refactor/*`, `docs/*`, `test/*`, `build/*`, `ci/*`, `chore/*`, `style/*`, `revert/*`, `main` (back-merge después de un hotfix), `dependabot/*` |
| `testing` | solo `develop` |
| `main` | `testing` o `hotfix/*` |

PRs desde forks hacia `testing` o `main`: rechazados.

## Adaptar las plantillas a un repo

Durante la instalación, abrí el workflow viejo que construía las imágenes y llevá a los nuevos todo lo que sea específico del repo:

- **Tests**: en `testing.yml`, el job `tests` trae un placeholder que solo emite un warning y pasa, para no bloquear mientras no haya tests. Reemplazalo por el comando real. Ejemplos:
  - **Python/FastAPI**: `actions/setup-python` → `pip install -r requirements.txt -r requirements-dev.txt` → `pytest -q`. Si los tests necesitan Postgres o Redis, agregá `services:` al job.
  - **Next.js**: `actions/setup-node` con `cache: npm` → `npm ci` → `npm run lint` → `npm test` → `npm run build`.
- **Docker**: `context`, `file` (si el Dockerfile no está en la raíz), `build-args`, `target` y `platforms` que usaba el workflow viejo.
- **Variables de build del front**: las `NEXT_PUBLIC_*` se hornean en el build. Si staging y producción usan URLs de API distintas, pasá build-args distintos en `testing.yml` y `release.yml` (`vars.API_URL_TESTING` / `vars.API_URL_PROD`).
- **Nombre de imagen**: por defecto `ghcr.io/${{ github.repository }}`. Si el repo publicaba con otro nombre que Dokploy ya usa, mantené ese nombre en `IMAGE_NAME`.
- **Tag de staging**: `STAGING_TAG: testing`. Si se cambia, hay que cambiarlo también en Dokploy.
- **Secrets**: si el workflow viejo usaba un PAT para GHCR en vez de `GITHUB_TOKEN`, conservalo.

## Workflow viejo

El patrón anterior (`on: push` en todas las ramas → `:develop`) debe desaparecer: con el flujo nuevo pisaría staging con ramas sin revisar. Si `testing.yml` + `release.yml` cubren todo lo que hacía, borralo en el PR de instalación. Si además hace otra cosa útil, limitá su `on:` y dejá solo esa parte.

## Mantenimiento

- Las versiones de las actions (`actions/checkout@v4`, `docker/*`) se pueden actualizar. Si se agrega Dependabot para `github-actions`, sus ramas `dependabot/*` ya están permitidas hacia `develop`. Sus títulos (`build(deps): …`, `ci(deps): …`) pasan `pr-title` si se configura `commit-message.prefix` en `dependabot.yml`.
- Si cambiás el `name:` de los jobs `pr-title` o `branch-policy`, tenés que cambiarlo también en `apply-rulesets.sh` y reaplicarlo. Si no, los PRs quedan esperando un check que nunca llega.
