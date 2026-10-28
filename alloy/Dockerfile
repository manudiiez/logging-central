# La configuración va horneada: la imagen es el artefacto versionado y el deploy
# es elegir un tag. Lo específico del entorno entra por variables (SERVICE_NAMESPACE,
# ENVIRONMENT), nunca por archivos montados.
FROM grafana/alloy:v1.21.2

COPY config.alloy /etc/alloy/config.alloy

# Se mantienen el ENTRYPOINT y el CMD de la imagen oficial, que ya apuntan a
# /etc/alloy/config.alloy. Corre como root porque necesita leer el socket de Docker.
