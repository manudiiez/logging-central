# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Qué es este repo

`logging-central` centraliza los logs de todas las apps del stack (api, crm, sync, …) en un único
lugar consultable. **No es una aplicación: es un repo de infraestructura.** Lo que versiona son un
`docker compose` y las configuraciones de los servicios que corren en el VPS.

Arquitectura:

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

El stack está implementado y verificado localmente: `docker compose up -d --build` lo levanta y
`bash scripts/smoke-test.sh` comprueba la ingesta de punta a punta. **Todavía no está desplegado en
el VPS**: falta crear la aplicación en Dokploy con `docker-compose.production.yml` y sacar la primera
versión (`vX.Y.Z`), y falta agregarle el label `logging: "true"` a los servicios de las otras apps.

Pendiente, deliberadamente fuera del alcance de la primera versión:

- Alertas en Grafana: se agregan cuando haya tráfico real con el que calibrar umbrales.
- Métricas y trazas. Esto es solo logs.

## Comandos

- Validar la configuración (lo que corre CI): `bash scripts/validate-config.sh`
  Valida los YAML trackeados, los dos compose, los dashboards de Grafana, `alloy validate` y
  `loki -verify-config`. Los validadores nativos usan la misma versión de imagen que cada
  Dockerfile, así que no hay deriva entre lo que se valida y lo que corre. Sin Docker saltea esa
  parte; sin PyYAML saltea la de YAML.
- Verificar la ingesta de punta a punta: `bash scripts/smoke-test.sh` (con el stack levantado).
  Emite logs de prueba desde un contenedor y comprueba los labels, los filtros por structured
  metadata, el timestamp y que una línea no-JSON no rompa el pipeline.
- Levantar el stack local: `docker compose up -d --build` (necesita `.env`, ver `.env.example`).
- No hay linter ni tests unitarios: en un repo de configuración, el equivalente son esos dos scripts.

## Al trabajar en este repo

- **Las versiones de las imágenes viven en los Dockerfiles** (`alloy/`, `loki/`, `grafana/`), que
  son la única fuente. `scripts/validate-config.sh` las lee de ahí; no las repitas en otro lado.
- **No agregues labels a Loki sin pensar la cardinalidad.** Si un campo puede tomar más de unos
  pocos valores, o crece con el tráfico, va como structured metadata en `alloy/config.alloy`, no
  como label. El smoke test falla si `request_id`, `user_id`, `level`, `event_name` o `trace_id`
  aparecen como labels.
- **Las imágenes de Loki y Alloy no tienen shell.** La de Loki es distroless (solo `/usr/bin/loki`):
  no se le puede poner un healthcheck de compose ni entrar con `exec sh`. La de Grafana sí.
- **Los secretos no se hornean.** `GRAFANA_ADMIN_PASSWORD` y cualquier credencial van por variable
  de entorno en Dokploy. Las imágenes son públicas en GHCR.
- Después de tocar `alloy/config.alloy` o `loki/loki.yml`, corré `scripts/validate-config.sh`; si
  tocaste el pipeline de parseo, corré además el smoke test con el stack levantado.

<!-- flujo-github:inicio -->
## Flujo de trabajo Git / GitHub

Este repo usa la skill **`flujo-github`** (`.claude/skills/flujo-github/SKILL.md`). Cargala **siempre** antes de hacer un commit, crear o leer issues, crear ramas, abrir PRs, promover ramas o crear tags de versión.

Lo esencial:

- Ramas permanentes: `develop` (por defecto, integración) → `testing` (staging) → `main` (versiones con tags `vX.Y.Z`).
- Nunca push directo a `develop`, `testing` ni `main`. Nunca mergear PRs: los mergea el usuario.
- Las ramas de trabajo salen de `develop`: `feat/N-slug`, `fix/N-slug`, `chore/…`. PR a `develop` con `Closes #N`.
- Commits y títulos de PR en Conventional Commits, descripción en español e imperativo.
- Al empezar: `git config core.hooksPath` debe ser `.githooks`.

Particularidades de este repo: se publican **tres** imágenes (`alloy`, `loki`, `grafana`) en vez de una, porque el stack son tres servicios y cada imagen hornea su configuración sobre la oficial de Grafana. `testing.yml` además levanta el stack y corre el smoke test antes de publicar. El job `config` de `pr-checks.yml` valida la configuración en cada PR, pero **no** es un check requerido por los rulesets: para volverlo obligatorio hay que agregarlo a `REQUIRED_CHECKS` en `.claude/skills/flujo-github/scripts/apply-rulesets.sh` y reaplicar.

### Scopes de este repo

`compose`, `alloy`, `loki`, `grafana`, `dashboards`, `retencion`, `scripts`, `ci`, `docs`, `repo`.

Ej.: `feat(alloy): descubrir contenedores por label logging=true`, `fix(loki): corregir ventana de retención`.

### Comandos

- Tests: `bash scripts/validate-config.sh` y, con el stack levantado, `bash scripts/smoke-test.sh`
- Lint: no hay; la validación va en esos scripts.
<!-- flujo-github:fin -->
