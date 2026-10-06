# deploy/development/pec/Dockerfile
# PEC e-SUS APS SÓ para desenvolvimento (prova técnica do módulo 16, ADR 0028).
# O instalador oficial é Linux x86-64 e espera systemd; no container não há init,
# então `systemctl`, `ps` e `file` são simulados só nas consultas que o
# instalador faz. Nunca use esta imagem fora de dev.
FROM --platform=linux/amd64 ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive TZ=America/Sao_Paulo LANG=pt_BR.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates wget gnupg locales tzdata postgresql-client file procps fontconfig \
    && locale-gen pt_BR.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

RUN wget -qO- https://apt.corretto.aws/corretto.key | gpg --dearmor -o /usr/share/keyrings/corretto.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/corretto.gpg] https://apt.corretto.aws stable main" \
       > /etc/apt/sources.list.d/corretto.list \
    && apt-get update && apt-get install -y --no-install-recommends java-17-amazon-corretto-jdk \
    && rm -rf /var/lib/apt/lists/*

RUN printf '#!/bin/sh\nexit 0\n' > /bin/systemctl && chmod +x /bin/systemctl \
    && mv /bin/ps /bin/ps.original \
    && printf '#!/bin/sh\nif [ "$1" = "--no-headers" ] && [ "$4" = "1" ]; then echo systemd; else exec /bin/ps.original "$@"; fi\n' > /bin/ps \
    && chmod +x /bin/ps \
    && mv /usr/bin/file /usr/bin/file.original \
    && printf '#!/bin/sh\nif [ "$1" = "-L" ] && [ "$2" = "/sbin/init" ]; then echo "/sbin/init: ELF 64-bit LSB executable, x86-64, systemd"; else exec /usr/bin/file.original "$@"; fi\n' > /usr/bin/file \
    && chmod +x /usr/bin/file

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
