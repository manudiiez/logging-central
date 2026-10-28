FROM grafana/grafana:13.3.0

# Datasource y dashboards provisionados por archivo. Los dashboards NO van en
# /var/lib/grafana: ahí se monta el volumen con la base de datos de Grafana y
# taparía lo horneado acá.
COPY provisioning/ /etc/grafana/provisioning/
COPY dashboards/   /etc/grafana/dashboards/
