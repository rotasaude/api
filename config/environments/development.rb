require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.enable_reloading = true
  config.eager_load = false
  config.consider_all_requests_local = true

  config.cache_classes = false
  config.cache_store = :solid_cache_store

  config.active_record.migration_error = :page_load
  config.active_record.verbose_query_logs = true

  config.action_mailer.raise_delivery_errors = false
  config.action_mailer.delivery_method = :test

  config.active_support.deprecation = :log

  # false (não o default do Rails para dev): primary/admin/queue/cache
  # compartilham o MESMO banco físico (rota_saude_development). Um dump
  # automático depois de qualquer db:migrate/db:prepare capturaria TODAS as
  # tabelas ali (domínio incluso, enquanto o Plano 5 não reparenta) em
  # db/schema.rb, db/queue_schema.rb, db/cache_schema.rb e db/admin_schema.rb —
  # sujando de volta os dumps limpos da Task 4 (banco por cidade). Dump
  # continua disponível sob demanda via `bin/rails db:schema:dump[:<config>]`.
  config.active_record.dump_schema_after_migration = false

  # Liberar hostnames internos do docker-compose para o Host Authorization.
  # O dashboard (Vite) proxa para "http://api:3000" — sem isso o Rails
  # responde 403 "Blocked hosts: api:3000".
  config.hosts << "api"
  config.hosts << "api:3000"
end
