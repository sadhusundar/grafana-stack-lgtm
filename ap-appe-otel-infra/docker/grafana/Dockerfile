FROM grafana/grafana:11.0.0

COPY provisioning/datasources.yml /etc/grafana/provisioning/datasources/datasources.yml

EXPOSE 3000

ENV GF_PATHS_PROVISIONING=/etc/grafana/provisioning
ENV GF_FEATURE_TOGGLES_ENABLE=traceqlEditor
