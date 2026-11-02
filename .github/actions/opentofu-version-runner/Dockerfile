FROM debian:stable-slim

ARG VERSION

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        make \
        unzip \
        sudo \
        shellcheck \
        wget \
    && rm -rf /var/lib/apt/lists/*

RUN wget -O tofu_amd64.deb "https://github.com/opentofu/opentofu/releases/download/v${VERSION}/tofu_${VERSION}_amd64.deb" \
    && dpkg -i tofu_amd64.deb \
    && rm -rf tofu_amd64.deb

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
