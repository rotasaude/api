# syntax=docker/dockerfile:1
# Imagem única para os papéis "web" e "worker" do rota-saúde.
# O papel é escolhido pelo comando final (ver deploy/*/deploy.yml).
# Ver ADR-0001 (Solid Queue) e ADR-0002 (imagem única + roles via Kamal).

ARG RUBY_VERSION=3.3.6
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

WORKDIR /rails

ENV BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    RAILS_ENV="production"

# postgresql-client-16 do repositório PGDG (Plano 4): o pg_dump precisa ser da
# mesma versão major do servidor ou mais nova, o Postgres de produção é o 16 e o
# postgresql-client do Debian é o 15.
#
# ca-certificates (abaixo) já cobre o lado do CLIENTE para CITY_DATABASE_SSLMODE
# passar de "require" para "verify-full" (Plano 8, Task 10) — falta só o lado do
# SERVIDOR (certificado no acessório postgres). Procedimento e ordem completos
# em deploy/production/deploy.yml (comentário junto de CITY_DATABASE_SSLMODE) —
# única fonte, não copie a ordem para outro lugar. Não mude nada aqui por causa
# disso: esta linha já está pronta.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y ca-certificates curl && \
    install -d /usr/share/postgresql-common/pgdg && \
    curl -fsSLo /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc && \
    . /etc/os-release && \
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      libjemalloc2 \
      libvips \
      postgresql-client-16 \
      tzdata && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Módulo 24c (ADR 0053): CLI go-pmtiles, que recorta o mapa offline de cada
# município (FieldMaps::Cli). Versão fixada pela prova técnica do app de campo
# (contrato do 24c, Q12); o SHA-256 de cada arquitetura é o da página de
# releases de protomaps/go-pmtiles. Mudou a versão? Troque os três valores.
ARG PMTILES_VERSION=1.31.2
ARG PMTILES_SHA256_AMD64=3ed7dbf4ec2e6dfe5e25b6f70d1ffc932729f93c86db353bf514dd71010a312f
ARG PMTILES_SHA256_ARM64=f8bd47e7ea866863489cad588fbaf2f31f42e5821f7a03f009b3769f05801cb1
RUN arch="$(dpkg --print-architecture)" && \
    case "$arch" in \
      amd64) asset="go-pmtiles_${PMTILES_VERSION}_Linux_x86_64.tar.gz"; sha="${PMTILES_SHA256_AMD64}" ;; \
      arm64) asset="go-pmtiles_${PMTILES_VERSION}_Linux_arm64.tar.gz"; sha="${PMTILES_SHA256_ARM64}" ;; \
      *) echo "go-pmtiles: arquitetura sem binário: $arch" >&2; exit 1 ;; \
    esac && \
    curl -fsSLo /tmp/pmtiles.tar.gz "https://github.com/protomaps/go-pmtiles/releases/download/v${PMTILES_VERSION}/${asset}" && \
    echo "${sha}  /tmp/pmtiles.tar.gz" | sha256sum -c - && \
    tar -xzf /tmp/pmtiles.tar.gz -C /usr/local/bin pmtiles && \
    rm /tmp/pmtiles.tar.gz && \
    pmtiles version


FROM base AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential \
      git \
      libpq-dev \
      libyaml-dev \
      pkg-config && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

COPY Gemfile Gemfile.lock .ruby-version ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile --gemfile

COPY . .

RUN bundle exec bootsnap precompile app/ lib/

# API-only — sem assets para precompilar. db:prepare roda no entrypoint do
# papel web, não em build time (ADR-0002).


# --- Stage de desenvolvimento/test (usado APENAS pelo docker-compose local) -----
# Inclui os grupos development/test + build tools (herdados do stage `build`) para
# rodar a suíte RSpec dentro do container, de forma durável (sobrevive a recreate).
# Produção NÃO usa este stage — é buildada via Kamal a partir do stage final slim
# (ADR-0002). O docker-compose aponta `target: development`.
FROM build AS development

ENV BUNDLE_DEPLOYMENT="0" \
    BUNDLE_WITHOUT="" \
    RAILS_ENV="development"

# O stage `build` instalou só os grupos de produção (BUNDLE_WITHOUT=development:test).
# Reinstala incluindo development/test. Single-job evita o crash do instalador
# paralelo do bundler observado neste ambiente; retry cobre falhas transitórias.
RUN bundle config set --local jobs 1 && bundle install --retry 5

RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    chown -R rails:rails db log storage tmp
USER 1000:1000

ENV LD_PRELOAD="libjemalloc.so.2" \
    MALLOC_CONF="dirty_decay_ms:1000,narenas:2,background_thread:true"

ENTRYPOINT ["/rails/bin/docker-entrypoint"]
EXPOSE 3000
CMD ["./bin/rails", "server"]


FROM base

COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /rails /rails

RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    chown -R rails:rails db log storage tmp
USER 1000:1000

ENV LD_PRELOAD="libjemalloc.so.2" \
    MALLOC_CONF="dirty_decay_ms:1000,narenas:2,background_thread:true"

ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Default = papel web. O papel worker sobrescreve via CMD em deploy.yml:
#   roles:
#     worker:
#       cmd: ./bin/city_workers
EXPOSE 3000
CMD ["./bin/rails", "server"]
