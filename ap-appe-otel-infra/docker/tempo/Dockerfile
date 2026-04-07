FROM grafana/tempo:2.6.1

COPY tempo.yml /etc/tempo/config.yml

EXPOSE 3200 4317 4318

CMD ["-config.file=/etc/tempo/config.yml", "-config.expand-env=true"]
