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
