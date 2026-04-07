###############################################################################
# docker/thanos/Dockerfile
# Base image unchanged; adds bucket.yml config for sidecar + query.
###############################################################################

FROM quay.io/thanos/thanos:v0.35.1

# Copy S3 objstore config — env vars (S3_BUCKET, AWS_REGION) expanded at runtime
COPY bucket.yml /etc/thanos/bucket.yml

EXPOSE 10901 10902

ENTRYPOINT ["/bin/thanos"]
