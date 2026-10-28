# El colector de logs

## Cómo funciona

```
contenedores de cada app ──stdout JSON──▶ Alloy ──push──▶ Loki ──consulta──▶ Grafana
                              (socket de Docker)
```

Ninguna app manda logs a ningún endpoint. Escriben JSON a stdout, que es lo que ya hacen, y
**Grafana Alloy** los lee del socket de Docker del host, les parsea el JSON y los empuja a **Loki**.
Grafana consulta Loki con LogQL.

La consecuencia práctica: sumar una app no requiere un shipper, un SDK ni tocar su código. Por eso
se eligió así, con apps en lenguajes distintos.

## Sumar una app nueva

1. Que escriba **un objeto JSON por línea a stdout**, siguiendo el contrato de campos (abajo).
2. Agregarle el label `logging=true` a su servicio en el compose:

   ```yaml
   services:
     mi-app:
       image: ghcr.io/manudiiez/mi-app:v1.0.0
       labels:
         logging: "true"
   ```

3. Nada más. Alloy la descubre en el siguiente ciclo (15 s).

Sin el label `logging=true` el contenedor se ignora. Es opt-in a propósito: evita tragarse los logs
de cualquier contenedor que pase por el host.

Un contenedor que **no** emite JSON (postgres, redis, un proxy) igual se puede recoger con el mismo
label. Sus líneas llegan como texto crudo y quedan bajo `service_name` = nombre del contenedor.

## Contrato de campos

Un objeto JSON por línea, claves planas con puntos, basado en las convenciones semánticas de
OpenTelemetry. Los valores ausentes **se omiten**, no van en `null`. La referencia completa, con el
catálogo de eventos, está en `docs/logging.md` del repo de la api; para escribir o revisar el logging
de una app, usar la skill `structured-logging`.

Lo que el colector mira:

| Campo del log | Qué hace el colector |
|---|---|
| `timestamp` | Es el timestamp que indexa Loki. Si falta o no parsea, se usa el de Docker. |
| `service.name` | Label `service_name`. |
| `service.namespace` | Label `service_namespace`. |
| `deployment.environment.name` | Label `environment`. |
| `level`, `event.name`, `logger`, `service.version`, `request.id`, `trace_id`, `user.id`, `error.type`, `http.response.status_code` | Structured metadata: se filtran rápido, no crean streams. |
| todo lo demás | Queda en la línea, se filtra con `\| json`. |

## Qué se indexa y qué no

Solo cuatro labels: **`service_name`, `service_namespace`, `environment`, `container`**. Son valores
estáticos y acotados por el tamaño del despliegue.

Todo lo demás va como structured metadata. La razón: en Loki cada combinación distinta de labels es
un *stream* con su propio índice y sus propios chunks. Poner `request.id` como label crearía un
stream por request — cientos de miles de streams, el índice crece sin control y las consultas se
caen. Ni `level` va como label: filtrarlo por structured metadata (`| level="error"`) es igual de
rápido y no multiplica streams.

Si hace falta agregar un label nuevo, la pregunta es: *¿cuántos valores distintos puede tomar?* Si la
respuesta no es "unos pocos, y no crecen con el tráfico", va como structured metadata.

## Consultas

```logql
# Todo lo de un servicio
{service_name="api", environment="production"}

# Un request de punta a punta, incluidos los jobs que disparó
{environment="production"} | request_id="01JB8Z6Q4K3M"

# Errores de las últimas horas, por servicio
sum by (service_name) (count_over_time({environment="production"} | level=~"error|fatal" [5m]))

# Los tipos de error más frecuentes
topk(10, sum by (error_type) (count_over_time({environment="production"} | level="error" [1h])))

# Requests lentos: hace falta parsear el JSON para comparar un número
{service_name="api"} | json | duration_ms > 1000

# Un endpoint concreto
{service_name="api"} | event_name="http.request_completed" | json | http_route="/listings/{id}"
```

`| json` aplana las claves con puntos a guiones bajos: `http.route` se consulta como `http_route`.

Loki además detecta el nivel por su cuenta y lo expone como `detected_level`. Es útil para los
contenedores que no siguen el contrato; para los que sí, usar `level`, que es el del log.

## Retención y límites

Definidos en `loki/loki.yml`, versionados a propósito: cambiarlos es un commit que se revisa.

| Qué | Valor | Dónde |
|---|---|---|
| Retención | 30 días (`720h`) | `limits_config.retention_period` |
| Se rechazan logs con timestamp más viejo que | 7 días | `reject_old_samples_max_age` |
| Tope de ingesta | 8 MB/s, ráfaga 16 MB | `ingestion_rate_mb` |
| Tope de streams | 5000 | `max_streams_per_user` |
| Tope por línea | 256 KB | `max_line_size` |

Al **bajar** la retención, el compactor borra lo que queda fuera de la ventana en el siguiente ciclo
(10 min). Es irreversible: lo borrado no vuelve.

Los topes están para que una app que se vuelve loca no tire abajo el colector entero. Si una app
legítima los toca, se suben con un commit, no desactivándolos.

## Deploy en el VPS

Las tres imágenes se publican en GHCR con la versión del repo:

```
ghcr.io/manudiiez/logging-central/alloy:vX.Y.Z
ghcr.io/manudiiez/logging-central/loki:vX.Y.Z
ghcr.io/manudiiez/logging-central/grafana:vX.Y.Z
```

La configuración va **horneada** en la imagen: el artefacto es inmutable y el deploy es elegir un
tag. En Dokploy se usa `docker-compose.production.yml` con estas variables:

| Variable | Ejemplo | Obligatoria |
|---|---|---|
| `STACK_VERSION` | `v1.2.0` (o `testing` para staging) | sí |
| `ENVIRONMENT` | `production` | sí |
| `GRAFANA_ADMIN_PASSWORD` | — | sí |
| `GRAFANA_ROOT_URL` | `https://logs.midominio.com` | sí |
| `SERVICE_NAMESPACE` | `nazar` | no (default `nazar`) |
| `GRAFANA_PORT` | `3000` | no |

**Rollback**: cambiar `STACK_VERSION` al tag anterior y redeployar. Los datos no se tocan: viven en
los volúmenes, no en las imágenes.

Lo único que no se hornea son los secretos. `GRAFANA_ADMIN_PASSWORD` va en Dokploy; si termina en un
archivo del repo, es un incidente.

Requisitos en el host:

- Alloy necesita `/var/run/docker.sock` montado en **solo lectura**. Lee los logs, no controla Docker.
- Loki **no se expone**: solo Alloy y Grafana lo alcanzan por la red interna del stack. El único
  puerto publicado es el de Grafana.
- Las apps a recoger tienen que correr en el mismo daemon de Docker que Alloy.

## Si no llegan logs

En orden, que es también el orden de probabilidad:

1. **¿Tiene el label?** `docker inspect <contenedor> --format '{{.Config.Labels}}'` tiene que incluir
   `logging:true`. Es la causa más común.
2. **¿Alloy ve el target?** `docker compose logs alloy`. La UI de Alloy en el puerto 12345 del
   contenedor muestra los componentes y sus targets.
3. **¿Loki está rechazando?** Los logs de Loki muestran los rechazos por límite o por timestamp
   viejo (`reject_old_samples`). Un reloj desfasado en el host dispara esto.
4. **¿El JSON es válido?** Una línea mal formada llega igual, pero sin labels ni structured metadata
   del contrato. Si ves tus logs bajo `service_name` = nombre del contenedor, el JSON no se parseó.
5. **¿Mirás la ventana de tiempo correcta?** Si la app emite timestamps en hora local en vez de UTC,
   los logs están en Loki pero fuera del rango que estás viendo.

## Desarrollo local

```bash
cp .env.example .env          # y poné una GRAFANA_ADMIN_PASSWORD
docker compose up -d --build
bash scripts/smoke-test.sh    # verifica la ingesta de punta a punta
```

Grafana queda en http://localhost:3000 y Loki, solo en local, en http://localhost:3100.

`scripts/validate-config.sh` valida las configs sin levantar nada: es lo que corre CI.
