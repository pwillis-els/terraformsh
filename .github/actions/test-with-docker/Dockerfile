FROM debian:stable-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
           ca-certificates curl git make unzip sudo \
    && rm -rf /var/lib/apt/lists/*


RUN sudo curl -fsSL -o /usr/local/bin/cliv https://raw.githubusercontent.com/peterwwillis/cliv/v2.4.0/cliv \
    && sudo chmod +x /usr/local/bin/cliv \
    && echo "3708fa6d60f90d2ca610337260b583afb945de1433344ad20bd06c23ccdebcdc  /usr/local/bin/cliv" | sha256sum -c \
    || { echo "FAILED CHECKSUM: REMOVING cliv" && sudo rm -f /usr/local/bin/cliv ; }

RUN cliv -E terraform

COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
