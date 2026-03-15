ARG TFVER
ARG TOFUVER
FROM hashicorp/terraform:$TFVER as terraform-binary

FROM debian:stable-slim
ARG TOFUVER
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
           ca-certificates curl git make unzip sudo shellcheck wget \
    && rm -rf /var/lib/apt/lists/*
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

COPY --from=terraform-binary /bin/terraform /usr/bin/terraform

RUN wget --no-verbose -O tofu_amd64.deb "https://github.com/opentofu/opentofu/releases/download/v${TOFUVER}/tofu_${TOFUVER}_amd64.deb" \
    && dpkg -i tofu_amd64.deb \
    && rm -rf tofu_amd64.deb
