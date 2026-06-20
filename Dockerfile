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

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      curl \
      libjemalloc2 \
      libvips \
      postgresql-client \
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
#       cmd: ./bin/jobs
EXPOSE 3000
CMD ["./bin/rails", "server"]
