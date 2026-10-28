# Eventos y niveles

Contenido:

1. Modelo: línea canónica más eventos discretos
2. Convención de nombres de eventos
3. Catálogo base, para adaptar a cada proyecto
4. Política de niveles detallada
5. Status HTTP y nivel
6. Dónde va cada log, por capa
7. Volumen y muestreo
8. Plantilla del catálogo para `docs/logging.md`

---

## 1. Modelo: línea canónica más eventos discretos

**Línea canónica (wide event).** Al terminar cada unidad de trabajo (request HTTP, job, mensaje consumido o ejecución de cron) se emite **un** evento con todo el contexto acumulado: identidad, ruta, status, duración, resultado, IDs de negocio, flags, número de reintentos y código de error. El middleware se encarga de la infraestructura (tiempo, status, IDs, emisión en `finally`) y los handlers solo **agregan contexto** al evento en curso, sin loguear. Stripe la usa en casi todos sus servicios porque responde la mayoría de las preguntas sin tener que juntar varias líneas.

**Eventos discretos.** Se emiten **además** de la línea canónica solo cuando:

- hay que alertar o auditar sobre algo puntual (seguridad o auditoría);
- ocurre fuera de un request (arranque, apagado, tareas programadas);
- describe un paso intermedio que la línea canónica no captura bien (reintento contra una dependencia, consulta lenta);
- es un error no controlado con stack trace.

Si dudás entre un evento discreto o un campo en la línea canónica, **elegí el campo**.

## 2. Convención de nombres de eventos

- Formato `dominio.accion_en_pasado`, en inglés y snake_case: `order.created`, `payment.failed`, `job.retry_scheduled`.
- Los nombres son estables: cambiarlos rompe alertas y dashboards. Se documentan en el catálogo.
- No se meten datos en el nombre: `order.created` con `order.id` como campo, nunca `order.created.9931`.
- En seguridad se respeta la semántica del **OWASP Logging Vocabulary**. Si querés interoperar con herramientas que la usan, el nombre OWASP puede ir en un campo `security.event`:

| `event.name` (proyecto) | OWASP Vocabulary | Nivel sugerido |
|---|---|---|
| `auth.login_succeeded` | `authn_login_success` | info |
| `auth.login_succeeded_after_failures` | `authn_login_successafterfail` | info |
| `auth.login_failed` | `authn_login_fail` | warn |
| `auth.login_failed_max` | `authn_login_fail_max` | warn |
| `auth.account_locked` | `authn_login_lock` | warn |
| `auth.password_changed` | `authn_password_change` | info |
| `auth.password_change_failed` | `authn_password_change_fail` | warn |
| `auth.token_created` | `authn_token_created` | info |
| `auth.token_revoked` | `authn_token_delete` | warn |
| `auth.token_invalid` | `session_*` / token reuse | warn |
| `authz.access_denied` | `authz_fail` | warn (OWASP lo marca CRITICAL; alertá por repetición, no por cada evento) |
| `authz.permission_changed` | `authz_change` | warn |
| `admin.action_performed` | `authz_admin` | info o warn |
| `input.validation_failed` | `input_validation_fail` | warn si sugiere manipulación (valor fuera de un conjunto cerrado); si no, solo un campo en la línea canónica |
| `upload.rejected` | `upload_*` | warn |
| `user.created` / `user.deleted` | `user_created` / `user_deleted` | info o warn |
| `data.exported` | `sensitive_*` / exportación | info |

## 3. Catálogo base (adaptar a cada proyecto)

**Ciclo de vida del proceso**

| Evento | Nivel | Campos clave |
|---|---|---|
| `system.started` | info | Versión, entorno, nivel de log, features activas (nada sensible). |
| `system.stopping` | info | Motivo (signal). |
| `system.config_invalid` | fatal | Nombre de la variable faltante o inválida, **nunca su valor**. |

**HTTP**

| Evento | Nivel | Campos clave |
|---|---|---|
| `http.request_completed` | según status (ver §5) | Línea canónica completa. |

**Errores**

| Evento | Nivel | Campos clave |
|---|---|---|
| `application.unhandled_exception` | error | `error.type`, `exception.*`, contexto. |

**Dependencias y datos**

| Evento | Nivel | Campos clave |
|---|---|---|
| `dependency.retry_scheduled` | warn | `peer.service`, `retry.attempt`, `error.type`, espera. |
| `dependency.failed` | error | `peer.service`, `error.type`, `duration_ms`, intentos totales. |
| `dependency.circuit_opened` | warn | `peer.service`. |
| `db.slow_query` | warn | `db.system.name`, `db.operation.name`, `db.collection.name`, `duration_ms`. |

**Jobs**

| Evento | Nivel | Campos clave |
|---|---|---|
| `job.started` | debug | `job.*`. |
| `job.completed` | info | Línea canónica del job: `job.*`, `duration_ms`, resultado, contadores. |
| `job.retry_scheduled` | warn | `job.*`, `error.type`. |
| `job.failed` | error | Solo cuando el fallo es **definitivo**, con `exception.*`. |

**Auditoría**

| Evento | Nivel | Campos clave |
|---|---|---|
| `audit.*` | info | Actor (`user.id`), acción, recurso (`<entidad>.id`), resultado y, si aplica, cambios **sin valores sensibles**. |

**Negocio**

| Evento | Nivel | Campos clave |
|---|---|---|
| `<entidad>.<accion>` | info | IDs, estado, montos. Solo si no alcanza con enriquecer la línea canónica. |

Los eventos de seguridad están en la tabla de §2.

## 4. Política de niveles detallada

| Nivel | OTel SeverityNumber | Significado | Producción |
|---|---|---|---|
| `trace` | 1–4 | Paso a paso interno. | Nunca. |
| `debug` | 5–8 | Diagnóstico técnico. | Apagado por defecto; se habilita puntualmente por variable de entorno. |
| `info` | 9–12 | Hechos normales y relevantes. | **Nivel por defecto.** |
| `warn` | 13–16 | Anomalía recuperable o evento de seguridad. | Sí. |
| `error` | 17–20 | Una operación no se completó por un fallo técnico. | Sí; es la base de las alertas. |
| `fatal` / `critical` | 21–24 | El proceso no puede seguir. | Sí; normalmente va seguido de la salida del proceso. |

Para elegir el nivel:

1. ¿El proceso no puede seguir? → `fatal`.
2. ¿Una operación que *debía* completarse no se completó por un problema del sistema o de una dependencia? → `error`.
3. ¿Algo anómalo que el sistema resolvió (reintento, fallback, lentitud), o algo relevante para seguridad? → `warn`.
4. ¿Es un hecho normal que alguien querría ver en producción? → `info`.
5. Si no, → `debug` o directamente no se loguea.

Reglas:

- Si nadie va a actuar ante un `error`, no es un `error`.
- Un error de un cliente o usuario (input inválido, recurso inexistente) **no** es `error` del sistema.
- El nivel lo decide el código que conoce el desenlace. Un reintento exitoso no es `error`, aunque el intento individual haya fallado.
- Los niveles se cambian con `LOG_LEVEL` sin tocar código. Si el stack lo permite, también por logger (`LOG_LEVEL_SQLALCHEMY=warning`).
- OWASP pide que no se pueda apagar por completo el logging de eventos requeridos por seguridad o cumplimiento.

## 5. Status HTTP y nivel de la línea canónica

| Status | Nivel | Notas |
|---|---|---|
| 1xx–3xx | info | |
| 400, 404, 409, 422 | info | Error del cliente. Va `error.type` si hay un código de dominio. |
| 401, 403 | info en la línea canónica | **Además** se emite el evento de seguridad correspondiente en `warn`. |
| 429 | warn | Puede indicar abuso o un límite mal calibrado. |
| 499 (cliente cerró) | info | Útil para detectar timeouts del lado del cliente. |
| 5xx | error | El detalle de la excepción va en `application.unhandled_exception`, no se duplica. |

## 6. Dónde va cada log, por capa

| Capa | Loguea | No loguea |
|---|---|---|
| Entrada (middleware, consumidor, wrapper de job) | Línea canónica, request ID, contexto, duración. | Bodies, headers completos. |
| Autenticación y autorización | Eventos de seguridad. | Credenciales, tokens, el hash de la contraseña. |
| Controller / handler | Solo agrega campos a la línea canónica. | Logs propios del tipo "entré al endpoint". |
| Servicio / caso de uso | Eventos de negocio y auditoría **después** de confirmar. | Pasos intermedios en `info`. |
| Repositorio / acceso a datos | Consultas lentas (`warn`) y diagnóstico en `debug`. | Errores que va a relanzar (los propaga con su causa). |
| Cliente de dependencia | Reintentos (`warn`), fallo definitivo (`error`, si nadie más lo maneja). | Payloads, tokens, URLs firmadas. |
| Handler global de errores | `application.unhandled_exception` con stack trace. | Detalles internos en la respuesta al cliente. |

## 7. Volumen y muestreo

- Health checks, readiness, liveness, `/metrics` y archivos estáticos se excluyen de la línea canónica, con una lista configurable.
- Con mucho tráfico, se usa **muestreo de cola**: se guarda el 100% de los errores, los 5xx, los requests lentos (por encima del p99 o de un umbral) y los eventos de seguridad, y solo un porcentaje de los requests exitosos rápidos. El muestreo se decide **al final**, con el resultado conocido, y se marca con `sampling.rate`.
- Si un mismo error se repite en ráfaga (una dependencia caída), conviene deduplicar o limitar la tasa en el logger para no inundar el backend.
- Revisá el costo: cada campo extra se multiplica por la cantidad de requests. Que la línea canónica sea completa no significa que sea gigante: nada de payloads.

## 8. Plantilla del catálogo para `docs/logging.md`

```markdown
| event.name | Nivel | Cuándo se emite | Campos específicos | Dueño |
|---|---|---|---|---|
| order.created | info | Después del commit de una orden nueva | order.id, order.total_cents, order.currency | equipo-checkout |
```
