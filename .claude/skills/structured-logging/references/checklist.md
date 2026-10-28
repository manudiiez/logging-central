# Checklist de revisión de logging

Usalo al terminar la implementación o al revisar un PR que toca logs. Cada ítem tiene que poder verificarse mirando el código o la salida real.

## Base
- [ ] Hay un único punto de configuración del logger por proceso, y se llama al arrancar.
- [ ] En producción la salida es JSON de una línea por evento, a stdout.
- [ ] No quedan `print`, `console.log` ni loggers configurados en otros módulos.
- [ ] Nivel y formato se configuran por variables de entorno.
- [ ] Las librerías ruidosas están en WARNING y el access log del servidor está desactivado (lo reemplaza la línea canónica).

## Contrato
- [ ] Cada línea trae `timestamp` (UTC, ISO 8601), `level`, `message`, `event.name`, `service.name`, `service.version` y `deployment.environment.name`.
- [ ] Los nombres siguen las convenciones semánticas de OTel. Los campos nuevos están documentados.
- [ ] Los mensajes son constantes y los datos van en campos.
- [ ] `http.route` usa la plantilla de la ruta, no la URL concreta.
- [ ] Los tipos son consistentes (IDs como string, duraciones en ms).

## Correlación
- [ ] El request ID se genera o se valida al entrar, se devuelve en la respuesta y está en todas las líneas del request.
- [ ] El request ID se propaga a los jobs encolados y a las llamadas salientes.
- [ ] Si hay OTel, `trace_id` y `span_id` se agregan automáticamente.

## Qué se registra
- [ ] Hay una línea canónica por request o job, emitida en `finally` (también ante errores).
- [ ] Están el arranque y el apagado.
- [ ] Están los eventos de seguridad: login exitoso y fallido, acceso denegado, tokens inválidos y cambios de credenciales o permisos.
- [ ] Hay auditoría de las acciones administrativas y de las eliminaciones o exportaciones.
- [ ] Los reintentos y los fallos definitivos de dependencias se registran con el nivel correcto.
- [ ] Las consultas lentas se registran por encima de un umbral, sin parámetros.
- [ ] Los eventos de negocio se emiten después de confirmar, una sola vez y en la capa correcta.

## Niveles
- [ ] Un 4xx de cliente no es `error`.
- [ ] Un 5xx produce `error` en la línea canónica más un único `application.unhandled_exception` con stack trace.
- [ ] Un reintento que terminó bien no genera `error`.
- [ ] No hay `debug` ruidoso en `info`.

## Errores
- [ ] Cada excepción se registra una sola vez, donde se maneja.
- [ ] La cadena de causas se conserva.
- [ ] La respuesta al cliente no expone stack trace ni detalles internos, e incluye el request ID.
- [ ] No hay `catch` vacíos o con solo un log que oculten errores.

## Seguridad y privacidad
- [ ] No hay bodies, headers completos, cookies, tokens, contraseñas, connection strings ni URLs prefirmadas.
- [ ] No hay datos personales directos: se usan IDs.
- [ ] La redacción automática está activa y probada, incluso con claves anidadas.
- [ ] Los valores del usuario no pueden inyectar líneas (JSON con escape, longitud limitada).
- [ ] Los mensajes de excepción y las URLs se sanean.

## Robustez y costo
- [ ] Un objeto no serializable o un error del logger no tira la aplicación.
- [ ] Los health checks y `/metrics` están excluidos.
- [ ] Si hay mucho volumen, hay muestreo de los éxitos sin perder errores ni requests lentos.
- [ ] Ningún campo de alta cardinalidad es una etiqueta del backend de logs.

## Tests y documentación
- [ ] Hay tests de formato, correlación, niveles por status, excepción única, redacción, inyección y jobs.
- [ ] `docs/logging.md` incluye el contrato, los niveles, el catálogo de eventos, las variables y un ejemplo.
- [ ] Hay verificación manual: se forzaron un 200, un 404, un 401, un 500 y un job fallido, y se revisó la salida real.
