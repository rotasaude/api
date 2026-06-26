require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = ENV["CI"].present?
  config.cache_store = :null_store

  config.consider_all_requests_local = true
  config.action_controller.perform_caching = false

  config.action_dispatch.show_exceptions = :rescuable

  config.action_mailer.delivery_method = :test
  config.action_mailer.perform_deliveries = true
  config.active_job.queue_adapter = :test

  config.active_support.deprecation = :stderr
  config.active_record.dump_schema_after_migration = false
end
