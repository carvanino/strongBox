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
        postgresql-client \
        argon2 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . /app

EXPOSE 8200

CMD ["bash", "-lc", "if [ -f /app/bin/strongbox ]; then exec bash /app/bin/strongbox; fi; source /app/lib/http.sh; http_serve"]
