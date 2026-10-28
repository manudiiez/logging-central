# Instalar el flujo en un repositorio (nuevo o ya en producción)

Objetivo: dejar el repo con `develop`/`testing`/`main` protegidas, CI alineado al flujo, Conventional Commits obligatorios y esta skill disponible, **sin modificar `main` ni romper el deploy actual**.

`SKILL_DIR` es la carpeta de esta skill (normalmente `.claude/skills/flujo-github`). Todos los scripts aceptan `--dry-run`.

## Fase 0 — Diagnóstico (solo lectura)

Ejecutá y anotá los resultados:

```bash
gh auth status                                   # sesión con permisos de admin sobre el repo
gh repo view --json nameWithOwner,visibility,defaultBranchRef,isPrivate,owner
gh api repos/{owner}/{repo} --jq '{allow_merge_commit,allow_squash_merge,allow_rebase_merge,delete_branch_on_merge}'
git fetch --all --prune --tags
git branch -r                                     # ramas existentes
git tag --sort=-v:refname | head                  # último tag de versión
gh pr list --state open                           # PRs abiertos y su rama base
gh api repos/{owner}/{repo}/rulesets              # rulesets existentes
ls .github/workflows/ && cat .github/workflows/*  # cómo se construyen hoy las imágenes
ls CLAUDE.md .claude/ 2>/dev/null
git status --porcelain                            # debe estar limpio
```

Detectá también el stack para los comandos de test y lint: `pyproject.toml` / `requirements*.txt` → Python (pytest, ruff); `package.json` → Node (`npm test`, `npm run lint`, revisar `scripts`).

### Preguntas que bloquean la instalación

1. **¿Existe `develop` con commits que no están en `main`?** `git rev-list --count origin/main..origin/develop`. Si es > 0, mostrale los commits al usuario: puede ser trabajo sin liberar. Opciones:
   - mergearlos a `main` por PR antes de seguir;
   - renombrar la rama vieja a `develop-old` y crear `develop` nueva desde `main`;
   - usar esa `develop` tal cual como base, si el usuario confirma que es lo que quiere.

   Nunca borres ni pises esos commits sin confirmación.
2. **Lo mismo para `testing`**, si ya existe.
3. **PRs abiertos contra `main`**: van a quedar pidiendo los checks nuevos. Listalos y preguntá si se re-apuntan a `develop` (`gh pr edit N --base develop`).
4. **Plan de GitHub**: los rulesets en repos **privados** requieren GitHub Pro (cuenta personal) o Team (organización). En Free solo funcionan en repos públicos. Si el repo es privado y el plan es Free, avisá: la protección queda a cargo del hook `pre-push` y de los permisos de Claude Code, que se pueden saltear. El resto de la instalación sigue igual.

Antes de ejecutar nada, presentale al usuario el plan con lo que vas a cambiar y esperá su confirmación. Cambiar la rama por defecto y aplicar rulesets afecta a todos los que usan el repo.

## Fase 1 — Ramas y configuración del repo

```bash
bash "$SKILL_DIR/scripts/bootstrap.sh"            # --dry-run primero
```

Qué hace:

- Crea `develop` y `testing` desde `origin/main` si no existen. Si existen y no tienen commits propios, las adelanta (fast-forward) a `main`. Si tienen commits propios, se detiene.
- No toca `main`.
- Pone `develop` como rama por defecto. Así los PRs apuntan ahí por defecto, `Closes #N` cierra issues al mergear en `develop` y los clones nuevos arrancan en `develop`.
- Configura el repo: merge commit y squash habilitados, rebase deshabilitado; el commit de squash usa el título del PR; las ramas de trabajo se borran solas después del merge.
- Crea las etiquetas: tipos, prioridades y `hotfix`.

## Fase 2 — Archivos (por PR, nunca directo)

```bash
git switch -c chore/configurar-flujo-github origin/develop
bash "$SKILL_DIR/scripts/install-files.sh"        # copia plantillas sin pisar existentes
```

`install-files.sh` copia lo siguiente. Si un archivo ya existe, **no lo pisa**: deja la versión nueva al lado con sufijo `.flujo-nuevo` para que la integres a mano.

| Origen (`templates/`) | Destino en el repo |
|---|---|
| `github/workflows/pr-checks.yml` | `.github/workflows/pr-checks.yml` |
| `github/workflows/testing.yml` | `.github/workflows/testing.yml` |
| `github/workflows/release.yml` | `.github/workflows/release.yml` |
| `github/ISSUE_TEMPLATE/*` | `.github/ISSUE_TEMPLATE/` |
| `github/pull_request_template.md` | `.github/pull_request_template.md` |
| `githooks/commit-msg`, `githooks/pre-push` | `.githooks/` (ejecutables) |
| `claude/settings.json` | se fusiona con `.claude/settings.json` (requiere `jq`) |
| `claude/CLAUDE.md.snippet` | se inserta en `CLAUDE.md` entre marcadores `<!-- flujo-github:inicio/fin -->` (idempotente) |
| la skill misma | `.claude/skills/flujo-github/`, si no está ya ahí |

También ejecuta `git config core.hooksPath .githooks`.

Después de copiar, el trabajo manual (lo hacés vos, Claude):

1. **Adaptar los workflows al repo** siguiendo `references/ci.md`: comando de tests real, Dockerfile y contexto, build-args, secrets que ya usaba el workflow viejo.
2. **Neutralizar el workflow viejo**: el que construía `:develop` en cualquier push **tiene que dejar de hacerlo**. Si no, cada push a una rama de trabajo sigue pisando la imagen de staging. Si su lógica ya quedó cubierta por `testing.yml` y `release.yml`, borralo en este mismo PR. Si hace otras cosas (migraciones, deploy hooks), recortá solo el disparador.
3. **Completar el bloque de `CLAUDE.md`**: scopes de este repo y comandos de test y lint.
4. Revisar los `.flujo-nuevo`, integrarlos y borrarlos.
5. Validar:
   - YAML: `python3 -c "import yaml,sys;[yaml.safe_load(open(f)) for f in sys.argv[1:]]" .github/workflows/*.yml`
   - Hooks: `printf 'feat: x\n' > /tmp/m && .githooks/commit-msg /tmp/m`
6. Commit: `chore(repo): configurar flujo develop/testing/main y conventional commits`.
7. `git push -u origin chore/configurar-flujo-github` y PR a `develop`. El usuario lo mergea con squash.

## Fase 3 — Reglas del repo

Con el PR de la fase 2 ya abierto, para que los checks existan:

```bash
bash "$SKILL_DIR/scripts/apply-rulesets.sh"       # --dry-run para ver el JSON
# opciones: --approvals 1 (si hay más de un dev), --no-checks (sin checks requeridos)
```

Crea o actualiza, de forma idempotente por nombre, estos rulesets **sin bypass**. Aplican también al admin, que es lo pedido:

| Ruleset | Rama/tag | Reglas |
|---|---|---|
| `flujo: develop` | `develop` | PR obligatorio (squash o merge), checks `pr-title` y `branch-policy`, sin force-push, sin borrado |
| `flujo: testing` | `testing` | PR obligatorio (solo merge commit), checks, sin force-push, sin borrado |
| `flujo: main` | `main` | PR obligatorio (solo merge commit), checks, sin force-push, sin borrado |
| `flujo: tags de version` | `v*` | Los tags no se pueden borrar ni mover (crear sí) |

Con esto, ni el usuario ni Claude pueden pushear a esas ramas: solo se entra por PR. Si el plan no soporta rulesets, el script lo detecta (HTTP 403) y lo informa sin fallar el resto.

## Fase 4 — Cierre

Informale al usuario:

1. El link del PR de configuración.
2. Lo que quedó aplicado: ramas, rama por defecto, rulesets, etiquetas.
3. **Pasos manuales:**
   - En Dokploy (o donde corra staging), cambiar la imagen de staging de `:develop` a `:testing`.
   - Mergear el PR de configuración y después promoverlo `develop → testing → main`. Hasta que llegue a `main`, los tags siguen usando el workflow viejo de release, que ya funcionaba.
   - En cada clon local existente: `git fetch --prune && git switch develop && git config core.hooksPath .githooks`.
4. Si el plan no soporta rulesets, que la protección es solo local.

Para replicarlo en otro repo, repetir desde la fase 0. La skill es la misma; cambian los scopes, los comandos de test y los detalles de build.
