FROM prom/prometheus:v2.51.0

COPY prometheus.yml /etc/prometheus/prometheus.yml

EXPOSE 9090

CMD ["--config.file=/etc/prometheus/prometheus.yml", \
     "--storage.tsdb.path=/prometheus", \
     "--storage.tsdb.retention.time=15d", \
     "--storage.tsdb.min-block-duration=2h", \
     "--storage.tsdb.max-block-duration=2h", \
     "--web.enable-lifecycle", \
     "--web.enable-remote-write-receiver"]
