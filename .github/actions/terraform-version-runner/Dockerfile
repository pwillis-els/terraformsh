ARG TFVER
FROM hashicorp/terraform:$TFVER as terraform-binary

FROM debian:stable-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
           ca-certificates curl git make unzip sudo shellcheck \
    && rm -rf /var/lib/apt/lists/*
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

#COPY entrypoint.sh /entrypoint.sh
#ENTRYPOINT ["/entrypoint.sh"]

COPY --from=terraform-binary /bin/terraform /usr/bin/terraform
