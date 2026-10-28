# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Qué es este repo

`logging-central` centraliza los logs de todas las apps del stack (api, crm, sync, …) en un único
lugar consultable. **No es una aplicación: es un repo de infraestructura.** Lo que versiona son un
`docker compose` y las configuraciones de los servicios que corren en el VPS.

Arquitectura decidida (todavía no implementada, ver "Estado"):

```
contenedores de cada app ──stdout JSON──▶ Grafana Alloy ──push──▶ Loki ──consulta──▶ Grafana
   (api, crm, sync, …)       (socket        (descubre por        (índice por      (LogQL,
                              de Docker)     labels de Docker)    labels)          dashboards, alertas)
```

Decisiones que no se deducen leyendo un archivo:

- **Las apps no mandan logs a ningún endpoint de este repo.** Escriben JSON a stdout y Alloy los
  recoge del socket de Docker. Así agregar una app nueva no requiere tocar su código ni un SDK por
  lenguaje, que es el punto: las apps están en tecnologías distintas.
- **Loki y no Elasticsearch**: Loki indexa solo labels y guarda el resto como structured metadata,
  así que entra en un VPS; un ELK pide ~2 GB de RAM solo para la JVM.
- **Labels (lo indexado) vs. campos**: solo van como label `service.name`, `level` y
  `deployment.environment.name`. Todo lo demás (`request.id`, `http.*`, `user.id`, …) es structured
  metadata o parte de la línea. Agregar labels de alta cardinalidad (ej. `request.id`) rompe Loki.
- **Contrato de los logs**: un objeto JSON por línea, claves planas con puntos, basado en
  OpenTelemetry semconv; los valores ausentes se omiten en vez de ir en `null`. Campos siempre
  presentes: `timestamp` (UTC ISO 8601 con ms y `Z`), `level`, `message`, `event.name`, `logger`,
  `service.name`, `service.namespace`, `service.version`, `deployment.environment.name`,
  `service.instance.id`, `process.pid`. Correlación por `request.id` (no hay `trace.id`/`span.id`).
  La referencia completa con el catálogo de eventos está en `docs/logging.md` **del repo de la api**;
  para diseñar o revisar logging, usar la skill `structured-logging`.

## Estado

Infraestructura del repo lista (flujo de GitHub, CI, hooks). **Todavía no existe el stack**: faltan
el `docker compose`, las configs de Alloy / Loki / Grafana, los dashboards y la política de
retención. Tampoco está decidido cómo se despliega al VPS (si Dokploy toma el repo o si un workflow
entra por SSH).

Mientras falte eso, no asumas estructura de carpetas más allá de la que ya existe: confirmala con el
usuario antes de crear scaffolding.

## Comandos

- Validar configuración (lo que corre CI): `bash scripts/validate-config.sh`
  Valida la sintaxis de todos los YAML trackeados y, cuando exista, el `docker compose`. Requiere
  PyYAML para la parte de YAML (`python3 -m pip install pyyaml`); sin él saltea ese paso con un aviso.
- No hay linter ni suite de tests aparte: en un repo de configuración, el equivalente es ese script.
  Cuando se agreguen las configs de Loki y Alloy, sumarles su validación nativa ahí mismo (hay un
  comentario `PENDIENTE` en el script con los comandos).

<!-- flujo-github:inicio -->
## Flujo de trabajo Git / GitHub

Este repo usa la skill **`flujo-github`** (`.claude/skills/flujo-github/SKILL.md`). Cargala **siempre** antes de hacer un commit, crear o leer issues, crear ramas, abrir PRs, promover ramas o crear tags de versión.

Lo esencial:

- Ramas permanentes: `develop` (por defecto, integración) → `testing` (staging) → `main` (versiones con tags `vX.Y.Z`).
- Nunca push directo a `develop`, `testing` ni `main`. Nunca mergear PRs: los mergea el usuario.
- Las ramas de trabajo salen de `develop`: `feat/N-slug`, `fix/N-slug`, `chore/…`. PR a `develop` con `Closes #N`.
- Commits y títulos de PR en Conventional Commits, descripción en español e imperativo.
- Al empezar: `git config core.hooksPath` debe ser `.githooks`.

A diferencia de los repos de aplicación, acá **ningún workflow publica imágenes**: el stack usa las imágenes oficiales de Grafana y lo que se versiona es la configuración. `testing.yml` y `release.yml` validan; el tag `vX.Y.Z` identifica la versión del compose que se despliega.

### Scopes de este repo

`compose`, `alloy`, `loki`, `grafana`, `alerts`, `retencion`, `scripts`, `ci`, `docs`, `repo`.

Ej.: `feat(alloy): descubrir contenedores por label logging=true`, `fix(loki): corregir ventana de retención`.

### Comandos

- Tests: `bash scripts/validate-config.sh`
- Lint: no hay; la validación va en el mismo script.
<!-- flujo-github:fin -->
