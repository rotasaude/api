require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false

  config.cache_store = :solid_cache_store

  config.active_record.dump_schema_after_migration = false
  config.active_record.encryption.support_unencrypted_data = false

  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")
  config.log_tags = [:request_id]
  config.logger = ActiveSupport::TaggedLogging.logger(STDOUT)

  config.action_mailer.delivery_method = :smtp
  config.action_mailer.smtp_settings = {
    address:        ENV.fetch("SMTP_ADDRESS", "smtp.example.com"),
    port:           ENV.fetch("SMTP_PORT", 587).to_i,
    user_name:      ENV["SMTP_USERNAME"],
    password:       ENV["SMTP_PASSWORD"],
    authentication: :plain,
    enable_starttls_auto: true
  }

  config.i18n.fallbacks = true
  config.active_support.report_deprecations = false
end
