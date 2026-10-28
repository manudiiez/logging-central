---
name: structured-logging
description: Diseña, implementa o revisa el logging de una aplicación backend (API, workers, jobs) con prácticas profesionales — JSON estructurado, línea canónica por request, eventos de seguridad y auditoría, correlación, redacción de datos sensibles y campos OpenTelemetry. Usar al agregar o corregir logs, configurar un logger, o preparar logs para Loki/ELK/Datadog, en cualquier lenguaje.
---

# Structured Logging

Guía para dejar el logging de un proyecto al nivel de un equipo profesional, sin importar el lenguaje ni el framework. Combina cinco fuentes:

- las convenciones semánticas de **OpenTelemetry** para los nombres de campos;
- el patrón de **línea canónica / wide events** (Stripe) para los requests;
- el **OWASP Logging Cheat Sheet** y su **Logging Vocabulary** para seguridad;
- las buenas prácticas de etiquetas de **Grafana Loki**;
- la regla de **"primero las preguntas, después la telemetría"**.

## Archivos de referencia (leer cuando haga falta)

| Archivo | Leerlo cuando… |
|---|---|
| `references/field-contract.md` | Definas los campos del JSON o nombres un campo nuevo. |
| `references/events-and-levels.md` | Decidas qué registrar, con qué nivel y con qué nombre de evento. |
| `references/security-privacy.md` | Haya datos personales, autenticación, tokens o input de usuarios (casi siempre). |
| `references/stacks.md` | Implementes en Python, Node/TypeScript, Go, Java o .NET. |
| `references/checklist.md` | Revises un PR o verifiques el trabajo al final. |

---

## Principios (no negociables)

1. **Estructurado siempre.** Un objeto JSON por línea en producción. Nada de strings concatenados, `print` ni `console.log`. Los valores van como campos, nunca interpolados en el mensaje.
2. **Un solo logger, configurado una vez** al arrancar cada proceso. El resto del código solo obtiene el logger. Formato, campos fijos, redacción y niveles se definen en un único lugar.
3. **stdout, no archivos.** En contenedores, la plataforma recoge stdout. Archivos solo si el entorno lo exige, y siempre con rotación y retención.
4. **Nombres estándar.** Se usan las convenciones semánticas de OpenTelemetry cuando existen (`http.request.method`, `exception.type`, `service.name`…). No se inventa un esquema propio.
5. **Una línea canónica por unidad de trabajo.** Cada request HTTP, job o mensaje consumido emite **un** evento rico al terminar, con duración, resultado y todo el contexto de negocio acumulado. Esto reemplaza al montón de logs sueltos.
6. **Eventos discretos solo donde aportan.** Seguridad, auditoría, ciclo de vida del proceso, reintentos o fallos de dependencias y errores no controlados van como eventos propios, porque hay que poder alertar o investigar sobre ellos aunque el request siga adelante.
7. **Cada error se registra una vez**, en el lugar que lo maneja, con stack trace. Las capas intermedias propagan conservando la causa: o loguean, o relanzan; nunca las dos cosas.
8. **Seguro por defecto.** Se loguean solo los campos permitidos (allowlist) y una redacción automática actúa como red de seguridad. Nunca secretos, tokens, bodies, headers completos ni datos personales directos.
9. **Correlación siempre.** `request.id` (o `trace_id` si hay OpenTelemetry) en todas las líneas de una unidad de trabajo, propagado a los jobs y a las llamadas salientes.
10. **El logging nunca rompe la aplicación.** Si falla el logging, la app sigue funcionando. Tampoco puede bloquear ni degradar notablemente el camino principal.
11. **Los logs no son métricas.** Contar requests, latencias o tasas de error es trabajo de métricas. No se agregan logs solo para contar.

---

## Flujo de trabajo

### Paso 1 — Explorar antes de tocar

Sin modificar nada, relevá y reportá:

- Lenguaje, framework y procesos que existen (API, workers, cron, consumidores de colas, CLI).
- Cómo se loguea hoy: librería, `print` o `console.log`, configuraciones dispersas, formatos.
- Puntos de entrada: middlewares, exception handlers globales, autenticación y autorización, cola de jobs.
- Dependencias externas: base de datos, APIs de terceros, almacenamiento, colas.
- Operaciones de negocio relevantes: creación, cambios de estado, pagos, publicaciones, eliminaciones, exportaciones.
- Datos sensibles que maneja: credenciales, tokens y datos personales (nombres, emails, documentos, teléfonos, direcciones, datos financieros o de salud).
- Dónde corre (Docker, Kubernetes, serverless, VM) y si hay un destino de logs definido (Loki, ELK, Datadog, CloudWatch…).

### Paso 2 — Escribir las preguntas que los logs deben responder

Antes de decidir qué loguear, anotá entre 3 y 6 preguntas que haría alguien investigando un incidente en producción. Por ejemplo:

- ¿Por qué falló el request X que reportó un usuario? (Se busca por `request.id`.)
- ¿Qué operaciones fallaron después del último deploy? (Se filtra por `service.version` y `error.type`.)
- ¿Hubo intentos de acceso no autorizados? (Eventos de seguridad.)
- ¿Por qué no se completó el job Y? (Se buscan los eventos `job.*` por `job.id`.)

Cada log que se agregue tiene que servir a alguna de esas preguntas. Si no sirve a ninguna, es ruido.

### Paso 3 — Proponer el plan y el catálogo de eventos

Presentá:

- la librería y la configuración elegidas (ver `references/stacks.md`);
- el contrato de campos (ver `references/field-contract.md`);
- el **catálogo de eventos** de este proyecto: nombre, nivel, cuándo se emite y campos (ver `references/events-and-levels.md`);
- las variables de entorno.

**Si el usuario está presente, esperá su aprobación antes de implementar.** Si trabajás sin supervisión, elegí la opción más conservadora, dejá anotadas tus decisiones y seguí.

### Paso 4 — Implementar la base

En este orden, con commits chicos:

1. **Configuración central del logger.** Formato (`json` o `console` según `LOG_FORMAT`), nivel (`LOG_LEVEL`), campos de recurso fijos (`service.name`, `service.version`, `deployment.environment.name`), timestamps en UTC ISO 8601 con milisegundos, y librerías ruidosas en WARNING.
2. **Redacción y saneamiento** como processor, formatter o serializer del logger (ver `references/security-privacy.md`).
3. **Contexto por unidad de trabajo** con el mecanismo nativo del lenguaje (contextvars, AsyncLocalStorage, MDC, context.Context), para no pasar IDs a mano.
4. **Middleware de request**:
   - lee o genera el `X-Request-ID`, lo bindea al contexto y lo devuelve en la respuesta;
   - al terminar, emite la **línea canónica** `http.request_completed` con método, ruta en forma de plantilla, status, duración, usuario y los campos de negocio que los handlers hayan agregado;
   - la emite también cuando hay excepciones, porque se genera en un bloque `finally`;
   - excluye health checks y endpoints de métricas.
5. **Handler global de errores**: registra `application.unhandled_exception` con `exception.*` completo y devuelve al cliente un mensaje genérico más el `request_id`, sin stack trace ni detalles internos.
6. **Jobs y workers**: el mismo patrón que el request. Al encolar se propaga el `request.id`; el job bindea `job.name`, `job.id` y `job.attempt` y emite `job.completed` o `job.failed` al final.
7. **Arranque y apagado**: `system.started` (versión, entorno, nivel de log; nada sensible) y `system.stopping`.
8. **Reemplazar todos los `print` y `console.log`** y los loggers configurados por separado.

### Paso 5 — Eventos de dominio, seguridad y dependencias

- **Seguridad** (OWASP): login exitoso y fallido, acceso denegado, token inválido o expirado, fallos de validación sospechosos, cambios de contraseña, bloqueos.
- **Auditoría**: quién hizo qué sobre qué recurso y con qué resultado (cambios de permisos, eliminaciones, exportaciones, acciones de administradores).
- **Negocio**: un evento por operación confirmada, emitido después del commit y en la capa que la confirma. Si alcanza con enriquecer la línea canónica, no se crea un evento aparte.
- **Dependencias**: reintentos en `warn` y fallos definitivos en `error`; el éxito con detalle en `debug` (o solo como duración agregada a la línea canónica).
- **Base de datos**: consultas lentas por encima de un umbral configurable en `warn`, sin parámetros.

### Paso 6 — Tests

Como mínimo:

- En formato JSON, cada línea es JSON válido y trae los campos obligatorios.
- El request ID se genera, se respeta cuando viene válido, se devuelve en la respuesta y aparece en todos los logs del request.
- Un 4xx de cliente no genera logs de excepción ni nivel `error`.
- Un error no controlado produce exactamente un `application.unhandled_exception` con stack trace y una línea canónica con status 500 y el mismo ID, y la respuesta no filtra detalles internos.
- La redacción oculta claves sensibles, también anidadas, y los valores largos se truncan.
- Un input con `\n`, `\r` o caracteres de control no puede crear líneas falsas.
- Los jobs loguean con `job.*` y el `request.id` propagado.
- Si el logging falla (serializer roto, objeto no serializable), la aplicación no se cae.

### Paso 7 — Documentar

Creá o actualizá `docs/logging.md` con:

- el contrato de campos;
- la política de niveles;
- el catálogo de eventos;
- las variables de entorno;
- un ejemplo de cómo agregar un log nuevo bien hecho;
- la lista de "no hacer".

### Paso 8 — Verificar con evidencia

Levantá la aplicación y forzá un request exitoso, un 404, un 401, un error 500 y un job que falle. Revisá la salida real:

- ¿Se encuentra todo con un solo `request.id`?
- ¿Los campos salen estructurados, sin `[object Object]` ni `repr` de objetos?
- ¿Aparece algún dato sensible?

Recorré `references/checklist.md` antes de dar el trabajo por terminado.

---

## Política de niveles (resumen)

| Nivel | Uso | Ejemplos |
|---|---|---|
| `debug` | Diagnóstico técnico. Apagado en producción. | Hit de caché, filas devueltas, detalle de una llamada externa exitosa. |
| `info` | Funcionamiento normal y hechos de negocio. | Línea canónica de un request 2xx, 3xx o 4xx; job completado; entidad creada; arranque. |
| `warn` | Algo anómalo pero recuperable, o relevante para seguridad. | Reintento, consulta lenta, login fallido, acceso denegado, degradación con fallback. |
| `error` | Una operación no se pudo completar por un problema técnico. | Excepción no controlada, 5xx, job con reintentos agotados, dependencia caída sin fallback. |
| `fatal` / `critical` | El proceso no puede seguir. | Configuración obligatoria ausente, falla de inicialización. |

Reglas clave:

- **Un 4xx no es `error`.** Es el cliente equivocándose, y el sistema funcionó bien.
- **Se alerta sobre `error` y sobre eventos de seguridad, no sobre `warn` sueltos.**
- **TRACE no existe en producción.**
- **Producción usa `info`; desarrollo, `debug`.** Se cambia por variable de entorno, sin tocar código.

El detalle y el mapeo a los números de severidad de OpenTelemetry están en `references/events-and-levels.md`.

---

## Forma de un evento (ejemplo)

Así se ve una línea canónica de un request que falló. Se muestra expandida, pero en la salida real ocupa una sola línea:

```json
{
  "timestamp": "2026-10-27T15:42:18.450Z",
  "level": "error",
  "message": "Request completado",
  "event.name": "http.request_completed",
  "logger": "app.middleware.logging",
  "service.name": "api",
  "service.namespace": "acme",
  "service.version": "1.8.2",
  "deployment.environment.name": "production",
  "request.id": "01JB8Z6Q4K3M",
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
  "user.id": "usr_1842",
  "http.request.method": "POST",
  "http.route": "/orders/{order_id}/pay",
  "http.response.status_code": 500,
  "duration_ms": 5012,
  "order.id": "ord_9931",
  "payment.provider": "stripe",
  "error.type": "PAYMENT_PROVIDER_TIMEOUT"
}
```

---

## Anti-patrones (rechazar en revisión)

- Logs de entrada y salida en cada función, o varios logs sueltos por request en lugar de enriquecer la línea canónica.
- El mismo error logueado en el repositorio, en el servicio y en el controller.
- `logger.error("Error: " + e)`: pierde el tipo y el stack trace y mezcla datos en el mensaje.
- Volcar objetos completos (`user`, `request`, `response`, `config`) o el `repr` de ORM.
- Usar campos de alta cardinalidad (IDs, rutas crudas, emails) como etiquetas del backend de logs.
- Mensajes con datos variables interpolados. El mensaje tiene que ser constante y los datos van en campos.
- Nombres de campo distintos para lo mismo (`userId`, `user_id`, `uid`).
- Loguear datos sensibles "porque es solo en debug".
- Elegir el nivel según cuánto preocupa al desarrollador y no según la política.
- `try/except: log; pass`: tragarse errores con un log no es manejarlos.

## Fuera del alcance de esta skill

Configurar el backend de logs (Alloy, Loki, Fluent Bit, ELK, Datadog), el SDK de trazas y las métricas. La skill deja los logs **listos** para todo eso. Si el usuario lo pide, se trata como otra tarea.

## Fuentes

- OpenTelemetry Logs Data Model y Semantic Conventions: https://opentelemetry.io/docs/specs/semconv/
- OWASP Logging Cheat Sheet: https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html
- OWASP Logging Vocabulary: https://cheatsheetseries.owasp.org/cheatsheets/Logging_Vocabulary_Cheat_Sheet.html
- Stripe, Canonical Log Lines: https://stripe.com/blog/canonical-log-lines
- Grafana Loki, buenas prácticas de etiquetas: https://grafana.com/docs/loki/latest/get-started/labels/bp-labels/
