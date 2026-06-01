FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        gawk \
        jq \
        netcat-openbsd \
        ncat \
        openssl \
        python3 \
        python3-pip \
        postgresql-client \
        argon2 \
    && pip3 install argon2-cffi --break-system-packages \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . /app
RUN chmod +x /app/bin/strongbox /app/bin/strongbox-verify

EXPOSE 8200

CMD ["bash", "-lc", "if [ -f /app/bin/strongbox ]; then exec bash /app/bin/strongbox; fi; source /app/lib/http.sh; http_serve"]
