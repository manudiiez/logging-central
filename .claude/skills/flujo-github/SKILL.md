---
name: flujo-github
description: Flujo de trabajo Git/GitHub del proyecto (ramas develop → testing → main, Conventional Commits, issues, PRs, promociones, versiones con tags, hotfix e instalación en un repo existente). Usar SIEMPRE antes de hacer un commit, crear o leer issues, crear ramas, abrir PRs, sacar una versión, o cuando se pida instalar/ordenar el flujo en un repositorio.
---

# Flujo de trabajo GitHub

Este repo usa tres ramas permanentes y ramas de trabajo cortas. **Nadie pushea directo a `develop`, `testing` ni `main`**: todo entra por Pull Request, y los PRs los mergea siempre el usuario, nunca Claude.

```
feat/42-filtro-precio ─┐
fix/57-listing-null ───┼─(PR squash)──▶ develop ──(PR merge)──▶ testing ──(PR merge)──▶ main ──▶ tag vX.Y.Z
chore/… ───────────────┘                  │                       │                      │
                                     solo CI               tests + imagen          nada; el tag crea
                                                          :testing / :sha-…        la imagen :vX.Y.Z
```

| Rama | Para qué | Quién escribe | Qué dispara CI |
|---|---|---|---|
| `develop` | Integración diaria. Rama por defecto del repo. De acá nacen todas las ramas de trabajo. | PRs (squash) desde ramas de trabajo; back-merge desde `main` | Checks de PR (título + política de ramas) |
| `testing` | Staging. Lo que se va a probar completo. | Solo PR `develop → testing` (merge commit) | Tests completos → si pasan, imagen Docker `:testing` y `:sha-<commit>` |
| `main` | Lo liberable. Cada tag es una versión candidata a producción. | Solo PR `testing → main` o `hotfix/* → main` (merge commit) | Push a `main`: nada. Push de tag `vX.Y.Z`: imagen `:vX.Y.Z` |

Qué versión corre en producción lo decide el usuario en el servidor (Dokploy), eligiendo el tag de la imagen.

## Reglas que Claude nunca rompe

1. Nunca `git push` a `develop`, `testing` o `main`. Nunca `--force` sobre ellas. Nunca borrar ni mover un tag `v*`.
2. Nunca mergear un PR (`gh pr merge`). Claude crea el PR y avisa; el usuario revisa y mergea.
3. Nunca commitear en una rama permanente. Si estás en una, creá una rama de trabajo primero.
4. Todo commit y todo título de PR sigue Conventional Commits (ver abajo). Si el hook `commit-msg` rechaza un mensaje, se corrige el mensaje; nunca se usa `--no-verify`.
5. Nunca crear un tag de versión ni una release sin que el usuario lo pida explícitamente.
6. Antes de cualquier operación, `git fetch --prune` y verificar que el árbol de trabajo esté limpio (`git status --porcelain`). Si hay cambios ajenos a la tarea, preguntar antes de tocarlos.

Al empezar a trabajar en el repo, verificá que el hook esté activo: `git config core.hooksPath` debe devolver `.githooks`. Si no, ejecutá `git config core.hooksPath .githooks`.

## Conventional Commits

Formato: `tipo(scope opcional)!: descripción`

- **Tipos:** `feat` (funcionalidad nueva), `fix` (corrección), `perf`, `refactor`, `docs`, `test`, `build`, `ci`, `chore`, `style`, `revert`.
- **Descripción:** en español, imperativo, minúscula inicial, sin punto final, máximo 72 caracteres en la primera línea. Ej.: `fix(listings): evitar precio null al sincronizar con MercadoLibre`.
- **Scope:** el módulo afectado. Usar los scopes definidos en `CLAUDE.md` del repo; si ninguno encaja, omitirlo antes que inventar uno nuevo cada vez.
- **Cambio que rompe compatibilidad:** `!` después del tipo/scope **y** un pie `BREAKING CHANGE: qué se rompe y cómo migrar`. En la API esto es crítico porque el CRM y el front dependen de ella.
- **Pie con el issue:** `Refs #N` en los commits intermedios.
- Un commit = un cambio coherente. Si el diff mezcla cosas, separalo en varios commits (`git add -p`).

Detalle, ejemplos y el mapeo a SemVer: `references/conventional-commits.md`.

## Ramas de trabajo

- Nacen **siempre** de `develop` actualizado: `git switch develop && git pull --ff-only && git switch -c <rama>`.
- Nombre: `<tipo>/<n°issue>-<slug-corto>` → `feat/42-filtro-precio`, `fix/57-listing-null`, `chore/88-actualizar-deps`. Sin issue: `<tipo>/<slug>`.
- Tipos de rama válidos: `feat`, `fix`, `perf`, `refactor`, `docs`, `test`, `build`, `ci`, `chore`, `style`, `revert`. Para urgencias en producción, `hotfix/` (ver Hotfix).
- Vida corta: si `develop` avanzó, actualizar con `git rebase origin/develop` (es tu rama, se puede reescribir) y `git push --force-with-lease` **solo sobre la rama de trabajo**.

## Tareas habituales

### "Creá un issue porque pasa X"

1. Si falta información clave (pasos para reproducir, qué se esperaba, entorno: local / testing / producción y versión), preguntá lo mínimo necesario. Si el usuario no está, creálo con lo que hay y marcá lo faltante en el cuerpo.
2. Antes de crear, buscá duplicados: `gh issue list --state all --search "<palabras clave>"`. Si hay uno, mostralo y preguntá si se usa ese.
3. Creálo siguiendo la estructura de `.github/ISSUE_TEMPLATE/` (bug o feature):
   ```bash
   gh issue create --title "<descripción corta>" --label "bug,prioridad:alta" --body-file /tmp/issue.md
   ```
   Etiquetas disponibles: tipo (`bug`, `feature`, `mejora`, `chore`, `docs`), prioridad (`prioridad:critica|alta|media|baja`), `hotfix`. Si es un bug en producción que bloquea, `prioridad:critica`.
4. Devolvé el número y el link.

### "Mostrame los issues" / "¿qué hay pendiente?"

- `gh issue list --state open --limit 50 --json number,title,labels,assignees,updatedAt` y resumí agrupando por prioridad.
- Para uno en particular: `gh issue view N --comments`. Leé también los comentarios: ahí suele estar el contexto real.

### "Resolvamos el issue N"

1. `gh issue view N --comments` para entender el problema completo. Si es ambiguo, preguntá antes de codear.
2. Rama desde `develop`: `fix/N-slug` o `feat/N-slug` según el tipo del issue. Opcional: `gh issue develop N --base develop --name fix/N-slug --checkout` (vincula la rama al issue).
3. Para bugs: escribí primero un test que reproduzca el fallo, verificá que falla, después arreglá.
4. Corré los tests y el linter del repo (comandos en `CLAUDE.md`). No abras PR con tests rotos.
5. Commits convencionales con `Refs #N`.
6. `git push -u origin <rama>` y abrí el PR a `develop`:
   ```bash
   gh pr create --base develop --title "fix(scope): descripción" --body-file /tmp/pr.md
   ```
   - El **título** del PR es el mensaje del commit final (squash), así que tiene que ser convencional.
   - El cuerpo sigue `.github/pull_request_template.md` e incluye `Closes #N`. Como `develop` es la rama por defecto, el issue se cierra solo cuando el usuario mergea. **No cierres el issue a mano.**
7. Avisá con el link del PR y un resumen de qué cambió y cómo probarlo. Ahí termina: el usuario revisa y mergea.

### "Pasá develop a testing" (promoción)

1. `git fetch --prune`. Mostrá qué entra: `git log --oneline origin/testing..origin/develop`. Si no hay nada, decilo y no abras PR.
2. Si ya hay un PR abierto `develop → testing`, no crees otro; mostrá el existente.
3. Abrí el PR:
   ```bash
   gh pr create --base testing --head develop --title "chore(release): promover develop a testing" --body "<lista de cambios con sus PRs/issues>"
   ```
4. Recordale al usuario que se mergea con **"Create a merge commit"** (no squash). Si se hace squash, las ramas divergen y la próxima promoción trae conflictos falsos.
5. Al mergear, CI corre los tests y, si pasan, publica la imagen `:testing`.

### "Pasá testing a main"

Igual que la anterior, con `--base main --head testing` y título `chore(release): promover testing a main`. Antes de abrir el PR, verificá que el último workflow de `testing` haya pasado: `gh run list --branch testing --limit 3`. Si falló, avisá y no abras el PR.

### "Sacá una versión" / "Creá el tag"

Solo cuando el usuario lo pide:

1. `git fetch --tags --prune`.
2. Calculá la versión sugerida: `bash .claude/skills/flujo-github/scripts/next-version.sh`. Lee los commits desde el último tag en `main`:
   - `BREAKING CHANGE` o `!` → major
   - `feat` → minor
   - `fix` o `perf` → patch
   - en `0.x`, un breaking change sube minor
3. Mostrale al usuario la versión sugerida y la lista de cambios, y esperá su confirmación. Si él dice otra versión, usá la suya.
4. Creá el tag anotado **sobre `origin/main`** y publicalo:
   ```bash
   git tag -a vX.Y.Z origin/main -m "vX.Y.Z"
   git push origin vX.Y.Z
   gh release create vX.Y.Z --verify-tag --generate-notes --title "vX.Y.Z"
   ```
5. CI construye la imagen `:vX.Y.Z`. El usuario la elige en Dokploy para producción.

### Hotfix (bug en producción que no puede esperar el ciclo normal)

Se usa cuando `testing`/`develop` tienen cambios que todavía no deben ir a producción.

1. Issue con labels `bug,hotfix,prioridad:critica`.
2. **Si producción está rota, primero rollback**: en Dokploy, volver a la imagen del tag anterior. Arreglar viene después.
3. Rama desde `main`: `git switch -c hotfix/N-slug origin/main`.
4. Fix mínimo + test. Commit `fix(scope): …` con `Refs #N`.
5. PR `hotfix/N-slug → main` (merge commit). Cuerpo con `Fixes #N`. El issue no se cierra solo porque `main` no es la rama por defecto; cerralo vos con comentario cuando esté desplegado y el usuario lo confirme.
6. Cuando el usuario mergea: tag patch (ver "Sacá una versión").
7. **Back-merge obligatorio:** PR `main → develop` con título `chore(release): back-merge vX.Y.Z a develop` y merge commit. Si no se hace, la próxima promoción pisa el fix.

## Si algo sale mal

- **Rechazo del push por reglas del repo** (`GH013`, `protected branch`): estabas pusheando a una rama protegida. Mové tus commits a una rama de trabajo (`git switch -c fix/…`) y abrí un PR. Nunca pidas desactivar las reglas.
- **El hook `pre-push` bloqueó**: lo mismo. Está ahí a propósito.
- **El check `pr-title` falló**: editá el título (`gh pr edit N --title "…"`).
- **El check `branch-policy` falló**: el PR va a una rama que no corresponde (ej. feature directo a `testing`). Cerralo y abrilo contra la rama correcta.
- **Conflictos en una promoción**: no los resuelvas en `testing` ni en `main`. Resolvelos en una rama `chore/resolver-conflictos-…` desde `develop` y mergeala a `develop` por PR; después promové.

## Instalar este flujo en un repositorio

Cuando el usuario pida "instalá / configurá / ordená el flujo de GitHub en este repo", seguí `references/instalacion.md` paso a paso. Resumen:

1. Diagnóstico sin tocar nada: plan de GitHub, ramas existentes, workflows actuales, PRs abiertos, `CLAUDE.md`.
2. Mostrar el plan y pedir confirmación.
3. `scripts/bootstrap.sh`: crea `develop` y `testing` desde `main` (sin tocar `main`), pone `develop` como rama por defecto, ajusta los métodos de merge y crea las etiquetas.
4. Rama `chore/configurar-flujo-github` con workflows adaptados, hooks, plantillas, bloque en `CLAUDE.md`, permisos de Claude Code y esta skill. PR a `develop`.
5. `scripts/apply-rulesets.sh`: protege las tres ramas y los tags `v*`.
6. Lista de pasos manuales que quedan, por ejemplo cambiar el tag de staging en Dokploy.

## Referencias

- `references/conventional-commits.md`: tipos, scopes, ejemplos buenos y malos, SemVer.
- `references/instalacion.md`: instalación en un repo nuevo o existente.
- `references/ci.md`: workflows de Actions y cómo adaptar los que ya existen.
- `templates/`: archivos que se copian al repo durante la instalación.
- `scripts/`: `bootstrap.sh`, `apply-rulesets.sh`, `install-files.sh`, `next-version.sh`.
