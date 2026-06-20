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
  config.active_record.dump_schema_after_migration = true

  # Liberar hostnames internos do docker-compose para o Host Authorization.
  # O dashboard (Vite) proxa para "http://api:3000" — sem isso o Rails
  # responde 403 "Blocked hosts: api:3000".
  config.hosts << "api"
  config.hosts << "api:3000"
end
