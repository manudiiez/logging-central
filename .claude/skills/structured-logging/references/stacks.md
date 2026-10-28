# Implementación por stack

Los ejemplos que siguen son **puntos de partida**. Antes de implementar, verificá las APIs contra la documentación de la versión instalada en el proyecto.

Contenido:

1. Python (structlog; FastAPI, Django, Flask; Celery, ARQ, RQ)
2. Node.js / TypeScript (pino; Express, Fastify, NestJS, Next.js)
3. Go (log/slog)
4. Java / Kotlin (Logback, Log4j2, Spring Boot)
5. .NET (Serilog o Microsoft.Extensions.Logging)
6. Variables de entorno estándar

---

## 1. Python

**Librería recomendada:** `structlog` integrado con `logging` de la stdlib vía `ProcessorFormatter`. Así los logs de las librerías (uvicorn, SQLAlchemy, httpx, Celery) salen en el mismo JSON. Alternativa mínima: `python-json-logger` sobre la stdlib.

### Configuración central (por ejemplo `app/core/logging.py`)

```python
import logging, sys, traceback
import structlog

def _resource(service_name, version, env):
    res = {"service.name": service_name, "service.version": version,
           "deployment.environment.name": env}
    def add_resource(_, __, ed):
        for k, v in res.items():
            ed.setdefault(k, v)
        return ed
    return add_resource

def _event_name(_, __, ed):
    # en el código se usa event_name="order.created" porque un kwarg no puede tener puntos
    if "event_name" in ed:
        ed["event.name"] = ed.pop("event_name")
    return ed

def _exception_to_otel(_, __, ed):
    exc = ed.pop("exc_info", None)
    if not exc:
        return ed
    if exc is True:
        exc = sys.exc_info()
    elif isinstance(exc, BaseException):
        exc = (type(exc), exc, exc.__traceback__)
    etype, evalue, tb = exc
    if etype is not None:
        ed["exception.type"] = f"{etype.__module__}.{etype.__qualname__}"
        ed["exception.message"] = sanitize(str(evalue))      # ver security-privacy.md
        ed["exception.stacktrace"] = "".join(traceback.format_exception(etype, evalue, tb))
        ed.setdefault("error.type", etype.__qualname__)
    return ed

def configure_logging(service_name, version, env, level="INFO", fmt="json"):
    shared = [
        structlog.contextvars.merge_contextvars,
        structlog.stdlib.add_log_level,
        structlog.stdlib.add_logger_name,
        structlog.processors.TimeStamper(fmt="iso", utc=True, key="timestamp"),
        _resource(service_name, version, env),
        _event_name,
        _exception_to_otel,
        redact_processor,                                     # ver security-privacy.md
        structlog.processors.EventRenamer("message"),         # structlog usa "event" para el mensaje
    ]
    structlog.configure(
        processors=[structlog.stdlib.filter_by_level, *shared,
                    structlog.stdlib.ProcessorFormatter.wrap_for_formatter],
        logger_factory=structlog.stdlib.LoggerFactory(),
        wrapper_class=structlog.stdlib.BoundLogger,
        cache_logger_on_first_use=True,
    )
    renderer = (structlog.processors.JSONRenderer() if fmt == "json"
                else structlog.dev.ConsoleRenderer())
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(structlog.stdlib.ProcessorFormatter(
        foreign_pre_chain=shared,
        processors=[structlog.stdlib.ProcessorFormatter.remove_processors_meta, renderer],
    ))
    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(level)
    for noisy in ("uvicorn.access", "sqlalchemy.engine", "httpx", "httpcore"):
        logging.getLogger(noisy).setLevel(logging.WARNING)
```

### Uso

```python
log = structlog.get_logger(__name__)
log.info("Orden creada", event_name="order.created", **{"order.id": order.id})
log.exception("Error no controlado", event_name="application.unhandled_exception")
```

Si escribir `**{"order.id": ...}` resulta incómodo, se puede agregar un helper `fields(order_id=...)` que traduzca a claves con punto. Lo importante es aplicar **una sola convención** en todo el proyecto.

### Contexto y línea canónica

- `structlog.contextvars.bind_contextvars(**{"request.id": rid})` al comenzar y `clear_contextvars()` al terminar cada request o job.
- **FastAPI / Starlette:**
  - Preferí un middleware **ASGI puro** antes que `BaseHTTPMiddleware`, que maneja peor los contextvars y el streaming.
  - `http.route` se lee después del ruteo: `request.scope["route"].path`.
  - La línea canónica se emite en un `finally` con el status real.
  - Desactivá el access log de uvicorn (`--no-access-log` o `log_config`).
  - La librería `asgi-correlation-id` resuelve el request ID si no querés escribirlo.
  - Usá `app.add_exception_handler(Exception, ...)` para el error no controlado.
- **Django:** middleware propio o `django-structlog`. Configurá `LOGGING` con el formatter de structlog.
- **Flask:** `before_request` / `teardown_request` o un middleware WSGI.
- **Jobs:**
  - Celery: señales `task_prerun`, `task_postrun` y `task_failure`.
  - ARQ: `on_job_start` / `on_job_end` o un wrapper de funciones.
  - RQ: un worker propio.

  El `request.id` se pasa como argumento o metadata del job y se bindea al empezar.
- **Consultas lentas en SQLAlchemy:** eventos `before_cursor_execute` y `after_cursor_execute` para medir. Se loguea la operación y la tabla, **nunca** `parameters`.
- **Tests:** `structlog.testing.capture_logs()` o `caplog`.

## 2. Node.js / TypeScript

**Librería recomendada:** `pino`, que emite JSON y es muy rápida. Para HTTP, `pino-http`. Fastify ya trae pino integrado y NestJS tiene `nestjs-pino`.

### Configuración central

```ts
import pino from "pino";
import { AsyncLocalStorage } from "node:async_hooks";

export const logContext = new AsyncLocalStorage<Record<string, unknown>>();

export const logger = pino({
  level: process.env.LOG_LEVEL ?? "info",
  messageKey: "message",
  timestamp: () => `,"timestamp":"${new Date().toISOString()}"`,
  base: {                                   // reemplaza pid/hostname por defecto
    "service.name": process.env.SERVICE_NAME,
    "service.version": process.env.SERVICE_VERSION,
    "deployment.environment.name": process.env.APP_ENV,
  },
  formatters: {
    level: (label) => ({ level: label }),   // "info" en vez de 30
    log: (obj) => mapErrorToOtel(obj),      // err -> exception.type/message/stacktrace
  },
  mixin: () => logContext.getStore() ?? {}, // request.id, user.id, trace_id
  redact: {
    paths: ["password", "*.password", "token", "*.token", "authorization",
            "*.authorization", "headers.cookie", "*.apiKey", "*.secret"],
    censor: "[REDACTED]",
  },
});
```

- `redact` de pino funciona **por ruta**, no por nombre de clave a cualquier profundidad. Para el resto, sumá una verificación por nombre de clave dentro de `formatters.log`.
- `pino-pretty` va solo en desarrollo, como pipe de CLI (`node app.js | pino-pretty`). No lo uses como transport en producción.
- Uso: `logger.info({ "event.name": "order.created", "order.id": id }, "Orden creada")`.
- Errores: `logger.error({ err, "event.name": "application.unhandled_exception" }, "Error no controlado")`. Usá `new Error(msg, { cause })` para encadenar causas.
- **Express:** middleware que hace `logContext.run({ "request.id": id }, next)` y emite la línea canónica en `res.on("finish")`. `http.route` sale de `req.route?.path` (con el prefijo de `req.baseUrl`).
- **Next.js:**
  - El logger se usa **solo en código de servidor** con runtime Node (route handlers, server actions, `instrumentation.ts`).
  - En runtime **Edge**, pino no está disponible. Usá un wrapper mínimo que escriba `console.log(JSON.stringify(...))` con el mismo contrato.
  - Si hay problemas de bundling, agregá `pino` a `serverExternalPackages`.
  - Nunca loguees desde componentes cliente hacia el servidor sin un endpoint dedicado y con limitación de tasa.
- **OpenTelemetry:** `@opentelemetry/instrumentation-pino` inyecta `trace_id` y `span_id`.

## 3. Go

**Librería recomendada:** `log/slog` de la stdlib (Go 1.21+) con `slog.NewJSONHandler(os.Stdout, opts)`.

- `ReplaceAttr` se usa para renombrar claves (`time` → `timestamp`, `msg` → `message`), forzar UTC y redactar por nombre de clave.
- Contexto: un `Handler` propio que lee `request.id`, `user.id` y `trace_id` desde `context.Context`. En el código se loguea siempre con `logger.InfoContext(ctx, ...)`.
- Tipos sensibles: implementar `slog.LogValuer` para que se rendericen como `[REDACTED]`.
- Errores: `slog.Any("error", err)`, con `%w` para encadenar. El stack trace no es automático; si hace falta, se captura en el punto de recuperación (`recover`).
- Middleware `net/http`: un wrapper de `ResponseWriter` que captura el status y emite la línea canónica en un `defer`.

## 4. Java / Kotlin

- **Spring Boot 3.4 o posterior:** trae logging estructurado nativo (`logging.structured.format.console=ecs` o `logstash`). Si no, Logback con `logstash-logback-encoder` o Log4j2 con `JsonTemplateLayout` (que soporta ECS y `maxStringLength`).
- Contexto con **MDC** (`MDC.put("request.id", id)`) en un `Filter` o `HandlerInterceptor`. Hay que limpiarlo siempre en `finally`. En código reactivo o asíncrono, propagar el contexto con Micrometer Context Propagation.
- Nunca concatenar strings en el template: usar `log.info("Orden creada {}", kv("order.id", id))` o la API fluida de SLF4J 2 (`log.atInfo().addKeyValue(...)`).
- Redacción: `MaskingJsonGeneratorDecorator` (logstash-logback-encoder) o un layout propio.

## 5. .NET

- **Serilog** con `RenderedCompactJsonFormatter` o `CompactJsonFormatter`, o la opción nativa `builder.Logging.AddJsonConsole()`.
- Contexto con `LogContext.PushProperty` (Serilog) o `ILogger.BeginScope`.
- `app.UseSerilogRequestLogging()` emite una línea por request, que funciona como línea canónica. Se enriquece con `IDiagnosticContext`.
- Redacción: destructuring policies (Serilog) o `Microsoft.Extensions.Compliance.Redaction`.
- Templates con placeholders (`"Orden {OrderId} creada"`), nunca con interpolación `$"..."`.

## 6. Variables de entorno estándar (todos los stacks)

| Variable | Por defecto | Uso |
|---|---|---|
| `LOG_LEVEL` | `info` (`debug` en desarrollo) | Nivel mínimo. |
| `LOG_FORMAT` | `json` | `json` o `console`. |
| `SERVICE_NAME` | — | `service.name`. |
| `SERVICE_NAMESPACE` | — | `service.namespace`. |
| `SERVICE_VERSION` | — | Tag o SHA, inyectado en el build o el deploy. |
| `APP_ENV` | — | `deployment.environment.name`. |
| `LOG_EXCLUDED_PATHS` | `/health,/healthz,/ready,/metrics` | Rutas sin línea canónica. |
| `LOG_SLOW_QUERY_MS` | `500` | Umbral de consulta lenta. |
| `LOG_SUCCESS_SAMPLE_RATE` | `1.0` | Muestreo de requests exitosos y rápidos (ver `events-and-levels.md` §7). |

Si `SERVICE_VERSION` o `APP_ENV` faltan en producción, el proceso emite un `warn` al arrancar. No se cae, salvo que el proyecto decida que es configuración obligatoria.
