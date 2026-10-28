# Seguridad y privacidad en logs

Basado en el OWASP Logging Cheat Sheet, CWE-117 (inyección en logs) y principios de minimización de datos (GDPR, Ley 25.326 de Argentina, LGPD y similares).

Contenido:

1. Qué nunca va a un log
2. Qué requiere tratamiento especial
3. Allowlist más redacción
4. Inyección en logs y saneamiento
5. Mensajes de excepción y URLs
6. Usuarios "de confianza"
7. Protección, acceso y retención
8. Fallas del logging

---

## 1. Qué nunca va a un log (en claro)

Según OWASP, estos datos se eliminan, se enmascaran o se hashean antes de registrar:

- Contraseñas, incluido el hash, y respuestas de preguntas de seguridad.
- Tokens de acceso o de refresh, API keys, secretos de cliente OAuth, firmas, códigos OTP o MFA, links mágicos.
- Identificadores de sesión y cookies de sesión. Si hace falta seguir una sesión, se usa un hash.
- Connection strings, claves de cifrado y secretos de configuración.
- Datos de tarjetas y cuentas bancarias.
- Datos personales sensibles: documentos de identidad (DNI, CUIT, SSN, pasaporte), salud, biometría, datos de menores.
- El código fuente.
- Datos de una clasificación de seguridad mayor a la que admite el sistema de logs.
- Información comercialmente sensible.
- Lo que sea ilegal recolectar en la jurisdicción, o lo que el usuario no consintió o pidió excluir.
- **Bodies de request y response, y headers completos.** Ahí suelen estar todos los anteriores.
- URLs prefirmadas (S3, R2, GCS), porque son credenciales con fecha de vencimiento.

## 2. Qué requiere tratamiento especial

Pueden ser útiles para investigar, pero hay que justificarlos y minimizarlos:

| Dato | Tratamiento sugerido |
|---|---|
| Email, nombre, teléfono, dirección | No se loguean. Se usa el ID interno. Si hace falta correlacionar, un hash con salt. |
| IP del cliente | Solo en eventos de seguridad, o truncada (/24 en IPv4, /48 en IPv6) en el resto. |
| User agent | Solo en eventos de seguridad. |
| Rutas de archivos y nombres de hosts internos | Evitarlos en mensajes que puedan llegar al cliente. En el log interno, con moderación. |
| Query strings | Se descartan o se pasan por la allowlist de parámetros. Suelen traer tokens. |
| Contenido generado por usuarios | Nunca completo. Si hace falta, el tamaño, el tipo o un hash. |

Cuando la identidad no es necesaria, se aplica seudonimización: borrar, mezclar o hashear los identificadores directos.

## 3. Allowlist más redacción (las dos)

**Primero, allowlist.** El código loguea solo campos elegidos explícitamente. Nada de `log.info("...", **request.__dict__)`, `logger.info({ req, res })` ni `log(user)`.

**Segundo, una red de seguridad automática** en la configuración central del logger, que se aplica a **todos** los eventos:

- Recorre claves anidadas, en dicts, listas y objetos.
- Si el nombre de la clave coincide (sin distinguir mayúsculas) con alguna de estas, reemplaza el valor por `"[REDACTED]"`:

  ```
  password, passwd, pwd, secret, token, access_token, refresh_token, id_token,
  authorization, auth, cookie, set-cookie, session, sessionid, api_key, apikey,
  x-api-key, private_key, client_secret, credential, signature, otp, pin,
  card, card_number, cvv, cvc, iban, account_number,
  ssn, dni, cuit, cuil, passport, tax_id, email, phone, telefono, mobile
  ```

- Opcionalmente, también por patrón de valor: JWT (`eyJ…\.…\.…`), `Bearer …`, números con forma de tarjeta (validados con Luhn) y claves con prefijos conocidos (`sk_live_`, `ghp_`, `AKIA`).
- Trunca los strings largos.
- Tiene que ser rápida: precompilá las expresiones y evitá recorrer objetos enormes. Si un objeto es muy grande, es señal de que no debería loguearse.

La redacción es la **última línea de defensa**, no la estrategia principal. Si detecta algo seguido, hay un bug en el código que loguea.

## 4. Inyección en logs (CWE-117) y saneamiento

- **Se usan formatos estructurados (JSON).** El serializer escapa `\n`, `\r` y las comillas, así que un valor de usuario no puede crear una línea falsa. Los formatos de texto plano son vulnerables a la inyección por CR/LF.
- El mensaje es **constante**. Los valores del usuario van en campos, nunca concatenados o interpolados en el mensaje (en Java/SLF4J, nada de concatenar en el template).
- Se limita la longitud de cada valor que viene del usuario.
- Los datos de otras zonas de confianza (headers como `X-Request-ID` o `X-Forwarded-For`, payloads de webhooks) se validan antes de usarlos. Si un campo viene malformado, se reemplaza o se omite y se registra la falla de validación, **sin descartar el evento entero**.
- En modo `console` (desarrollo), conviene escapar igual los caracteres de control para que una consola o un visor no interpreten secuencias ANSI maliciosas.

## 5. Mensajes de excepción y URLs

- Los mensajes de excepción de drivers y clientes HTTP suelen incluir la URL completa con su query string, connection strings o fragmentos del payload. **Hay que sanearlos** antes de ponerlos en `exception.message`.
- Las URLs se loguean sin query string, o con una allowlist de parámetros.
- Hay que tener cuidado con las excepciones de validación que repiten el valor recibido (por ejemplo, "email `juan@x.com` inválido"). Se loguea el campo y el tipo de error, no el valor.

## 6. Usuarios "de confianza"

OWASP indica no excluir eventos de actores "conocidos" (sistemas internos, terceros de confianza, bots de búsqueda, monitores, pentesters, auditores). En vez de excluirlos, se los marca: por ejemplo, `user.type = "internal_service" | "monitor" | "bot" | "pentest"`. La excepción son los health checks puramente técnicos, que se excluyen por ruido.

## 7. Protección, acceso y retención

Esto es responsabilidad de la plataforma, pero la app tiene que facilitarlo:

- Los logs no se exponen en rutas accesibles desde la web.
- El acceso de lectura se restringe y se audita.
- El transporte al backend va cifrado (TLS).
- La retención se define según el propósito y las obligaciones legales: los logs no se borran antes ni se guardan después del plazo.
- La auditoría con valor legal o de cumplimiento requiere almacenamiento inmutable o con detección de manipulación. Un log común no alcanza, así que se marca con `event.name` `audit.*` para poder enrutarla aparte.
- Los relojes de los servidores se sincronizan con NTP y los timestamps se emiten siempre en UTC.

## 8. Fallas del logging

- Que el logging falle (un objeto no serializable, un error en un processor, un disco lleno o un backend caído) **no puede tirar abajo la aplicación** ni filtrar información.
- Ante un objeto no serializable, se usa `str()` o un `repr` acotado, nunca una excepción.
- Si la escritura es asíncrona o con buffer, se acota el tamaño del buffer y se definen la política de descarte y el flush al apagar.
- El logging no puede usarse para agotar recursos (disco o cuota del backend). Por eso se limitan las tasas y los tamaños.
