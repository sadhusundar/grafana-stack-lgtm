FROM grafana/loki:3.3.2

COPY loki.yml /etc/loki/config.yml

EXPOSE 3100 9095

CMD ["-config.file=/etc/loki/config.yml", "-config.expand-env=true"]
