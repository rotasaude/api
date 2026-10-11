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

  # Plano 8: sem isto a lista fica vazia e o Rails PULA o HostAuthorization.
  # `.dominio` cobre api./admin./auth. e o curinga das cidades.
  require Rails.root.join("lib/platform_hosts").to_s
  # Rails.env, não o literal: config/environments/staging.rb herda este arquivo.
  config.hosts += PlatformHosts.for(Rails.env)
  config.host_authorization = { exclude: ->(request) { request.path == "/up" } }

  # Card api#62: rate_limit conta por request.remote_ip; atrás do proxy de borda
  # só com os CIDRs dele em trusted_proxies o Rails enxerga o IP real do cidadão.
  # Soma aos padrões do Rails (Rota.trusted_proxies); ausente → nil (o aviso sai
  # no initializer 02_trusted_proxies_warning), inválida → o boot falha.
  proxies = Rota.trusted_proxies(ENV["TRUSTED_PROXIES"])
  config.action_dispatch.trusted_proxies = proxies if proxies

  # CADSUS (ADR 0028): só a produção de verdade consulta o CADSUS de produção;
  # staging herda este arquivo e fica na homologação (default de SoapPdq.default_url).
  # Literal = Cadsus::SoapPdq::PRODUCTION_URL (constante não carrega em tempo de config).
  config.x.cadsus_pdq_url = "https://servicos.saude.gov.br/cadsus/PDQSupplier" if Rails.env.production?
end
