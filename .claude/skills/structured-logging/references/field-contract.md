# Contrato de campos

Se usan los nombres de las **convenciones semánticas de OpenTelemetry (OTel)** cuando existen. Así los logs se pueden mandar después por OTLP, o pasar a Loki, Elastic o Datadog, sin renombrar nada.

Contenido:

1. Formato general
2. Campos de recurso
3. Campos base del evento
4. Contexto y correlación
5. HTTP
6. Errores y excepciones
7. Dependencias externas y base de datos
8. Jobs, colas y mensajería
9. Dominio y negocio
10. Cómo nombrar un campo nuevo
11. Mapeo a backends

---

## 1. Formato general

- Un objeto JSON por línea en UTF-8, sin saltos de línea dentro del objeto.
- Las claves son **planas y con puntos** (`http.request.method`), que es como OTel modela los atributos. Si el stack obliga a usar objetos anidados (`{"http": {"request": {"method": ...}}}`), elegí una de las dos formas y usala en todo el proyecto.
- Los tipos son consistentes: los IDs siempre van como string, las duraciones como número en milisegundos (`duration_ms`) y los status como número.
- Los valores ausentes **se omiten**. No se completan con `null` ni con `""`.
- Los strings largos se truncan con un límite configurable, por defecto 2 KB. La excepción es `exception.stacktrace`, que tiene su propio límite, más grande (por ejemplo 16 KB).

## 2. Campos de recurso (iguales en todas las líneas de un proceso)

Se configuran **una sola vez** en el logger, nunca en cada llamada. En OTel son *resource attributes*.

| Campo | Ejemplo | Origen |
|---|---|---|
| `service.name` | `api`, `worker`, `scheduler` | Identifica el proceso. |
| `service.namespace` | `acme` | Agrupa los servicios de un mismo producto. |
| `service.version` | `1.8.2` o el SHA del commit | Variable de entorno inyectada en el build o el deploy. |
| `deployment.environment.name` | `production`, `staging`, `development` | Variable de entorno. |
| `service.instance.id` | ID del contenedor o pod (opcional) | Variable de entorno o hostname. |

Si la infraestructura ya agrega estos datos (labels de Kubernetes, Alloy o el driver de Docker), conviene igual que la app los emita: el log tiene que ser útil aunque se lea fuera de la plataforma.

## 3. Campos base del evento

| Campo | Obligatorio | Descripción |
|---|---|---|
| `timestamp` | Sí | UTC, ISO 8601 con milisegundos y `Z` (`2026-10-27T15:42:18.450Z`). |
| `level` | Sí | `debug`, `info`, `warn`, `error` o `fatal`, en minúsculas. Python puede emitir `warning` y `critical`; elegí una forma y documentala. |
| `message` | Sí | Texto corto y **constante** para humanos: "Request completado", "Login fallido". Sin datos interpolados. |
| `event.name` | Sí | Identificador estable `dominio.accion_en_pasado` (`order.created`). Es lo que se filtra, se cuenta y se alerta. |
| `logger` | Recomendado | Módulo que emite (`app.orders.service`). En OTel corresponde a `InstrumentationScope`. |

Para la convención de `event.name` y el catálogo, ver `events-and-levels.md`.

## 4. Contexto y correlación

| Campo | Cuándo | Notas |
|---|---|---|
| `request.id` | En todo lo que ocurre dentro de un request o job originado en un request | Se toma de `X-Request-ID` si viene y es válido (longitud de hasta 128 y caracteres `[A-Za-z0-9._-]`). Si no, se genera un UUIDv4, ULID o UUIDv7. |
| `trace_id`, `span_id` | Cuando hay un span de OTel activo | Los agrega un processor leyendo el contexto activo. Si se adopta OTel, `trace_id` puede reemplazar a `request.id`. |
| `user.id` | Si hay un usuario autenticado | Solo el ID interno, nunca el email ni el nombre. |
| `user.roles` | Opcional, en eventos de seguridad y auditoría | Por ejemplo `["admin"]`. |
| `tenant.id` | En sistemas multi-tenant | Es el campo de alta cardinalidad más útil para soporte. |
| `session.id` | Solo **hasheado**, si hace falta | OWASP desaconseja registrar el ID de sesión en claro. |

## 5. HTTP (servidor)

| Campo | Ejemplo | Notas |
|---|---|---|
| `http.request.method` | `POST` | |
| `http.route` | `/orders/{order_id}` | La **plantilla** de la ruta, nunca la URL concreta con IDs. |
| `url.path` | `/orders/9931` | Opcional. Nunca se incluye el query string completo. |
| `http.response.status_code` | `201` | |
| `duration_ms` | `142.7` | Desde que entra el request hasta que se envía la respuesta. |
| `client.address` | `203.0.113.7` | La IP real del cliente, si hay un proxy de confianza. Es un dato personal: incluila en eventos de seguridad y evaluá si hace falta en el resto. |
| `user_agent.original` | `Mozilla/5.0 …` | Opcional; útil en eventos de seguridad. |
| `http.request.body.size`, `http.response.body.size` | `512` | Opcional. **El tamaño, nunca el contenido.** |

Para cliente HTTP (llamadas salientes) se usa `server.address`, `server.port`, `http.request.method`, `http.response.status_code` y `duration_ms`.

## 6. Errores y excepciones

Según la convención semántica de OTel para excepciones en logs, que está en estado estable:

| Campo | Ejemplo | Notas |
|---|---|---|
| `error.type` | `PAYMENT_PROVIDER_TIMEOUT` o `TimeoutError` | **De baja cardinalidad.** Es el código de error estable de la aplicación o, si no hay uno, la clase de la excepción. Sirve para agrupar y alertar. |
| `exception.type` | `sqlalchemy.exc.OperationalError` | Nombre completo de la clase. |
| `exception.message` | `connection timed out` | **Saneado**, porque puede contener secretos, URLs con tokens o datos del usuario. |
| `exception.stacktrace` | `Traceback …` | En la representación natural del lenguaje, como un único string. Solo en el registro que *maneja* el error. |

Reglas:

- Se conserva la cadena de causas (`raise ... from e`, `new Error(msg, { cause })`, `%w` en Go). El stack trace muestra las causas encadenadas.
- Los errores esperables de dominio (validación, "no encontrado", conflicto) no llevan stack trace. Basta con `error.type` y el status.

## 7. Dependencias externas y base de datos

| Campo | Ejemplo |
|---|---|
| `server.address` | `api.stripe.com` |
| `peer.service` | `stripe` (nombre lógico de la dependencia) |
| `db.system.name` | `postgresql`, `redis`, `mongodb` |
| `db.operation.name` | `SELECT` o `findOne` |
| `db.collection.name` | `orders` (tabla o colección) |
| `retry.attempt` | `2` |
| `duration_ms` | `3001` |

**Nunca** se loguean el texto completo de la consulta con parámetros, las connection strings ni las credenciales. Si hace falta identificar una consulta, alcanza con la plantilla sin valores o un hash.

## 8. Jobs, colas y mensajería

| Campo | Ejemplo |
|---|---|
| `job.name` | `send_invoice_email` |
| `job.id` | `a1b2c3` |
| `job.attempt` | `3` |
| `job.queue` | `default` |
| `messaging.system` | `rabbitmq`, `kafka`, `sqs`, `redis` |
| `messaging.destination.name` | `orders.created` |
| `messaging.message.id` | `msg-5521` |
| `duration_ms` | `840` |
| `items.processed` / `items.failed` | `250` / `3` (en procesos batch) |

## 9. Dominio y negocio

- Los IDs de entidades van con namespace: `order.id`, `invoice.id`, `property.id`, `customer.id`.
- Los atributos de negocio útiles para responder preguntas van igual: `order.total_cents`, `plan.tier`, `feature_flag.<nombre>`, `payment.provider`.
- **Nunca** van datos personales directos (`customer.email`, `customer.name`, documentos, teléfonos). Se usa el ID.
- Montos: en la unidad mínima de la moneda (centavos) y con su moneda en `*.currency`.

## 10. Cómo nombrar un campo nuevo

1. Buscá si existe en OTel semconv (https://opentelemetry.io/docs/specs/semconv/). Si existe, usá ese nombre.
2. Si no existe, usá `namespace.atributo` en snake_case y en inglés (`listing.portal_status`).
3. Los nombres van en singular, sin abreviaturas ambiguas y sin el tipo en el nombre (`duration_ms` está bien porque la unidad aclara; `user_id_str` no).
4. Agregalo a `docs/logging.md`. Un campo no documentado es deuda técnica.

## 11. Mapeo a backends

| Backend | Qué hacer |
|---|---|
| **Grafana Loki** | Como etiquetas, solo `service_namespace`, `service_name` y `deployment_environment_name`: valores estáticos y acotados. **Ni siquiera `level`** conviene como etiqueta; según la documentación de Loki, suele ser igual de rápido filtrarlo con una expresión. `trace_id`, `request.id` y `user.id` van como *structured metadata* o se dejan en el JSON y se filtran con `\| json`. Nunca IDs, rutas crudas ni usuarios como etiqueta. |
| **OTel / OTLP** | `timestamp` → `Timestamp`; `level` → `SeverityText` + `SeverityNumber`; `message` → `Body`; los campos de recurso → `Resource`; el resto → `Attributes`. |
| **Elastic (ECS)** | ECS y OTel están convergiendo. Si el destino es Elastic, `service.name` y `error.*` ya coinciden y el resto se puede renombrar en el ingest pipeline. |
| **Datadog** | Reconoce `service`, `env`, `version` y `trace_id`/`dd.trace_id`. Mapealos en el agente o agregá alias en el logger. |
