require_relative "boot"

require "rails/all"

Bundler.require(*Rails.groups)

# Pré-declara Protocols para Zeitwerk usar como namespace de app/protocols/
# em vez de torná-la um root top-level. Sem isso, app/protocols/validator.rb
# carregaria como `Validator`, não `Protocols::Validator`. Ver ADR-0013.
module Protocols
end

require_relative "../lib/migration_helpers/rls"

module RotaSaude
  class Application < Rails::Application
    config.load_defaults 8.0

    config.api_only = true

    # ADR-0022: auth via cookie de sessão. API mode não habilita cookies
    # nem o session_store por default — re-adicionamos só esses dois.
    config.middleware.use ActionDispatch::Cookies
    config.middleware.use ActionDispatch::Session::CookieStore,
                          key: "_rota_saude_session",
                          httponly: true,
                          same_site: :lax,
                          secure: Rails.env.production?

    # ADR-0004: jobs disparados dentro de uma transação só são enfileirados
    # após o COMMIT. Em ROLLBACK, o job nunca chega ao worker.
    config.active_job.enqueue_after_transaction_commit = :always

    # ADR-0001: Solid Queue é o adapter padrão.
    config.active_job.queue_adapter = :solid_queue

    # Remove app/protocols/ dos roots default e re-registra com namespace.
    # Rails 8 adiciona automaticamente todos os app/<subdir> como roots.
    protocols_root = Rails.root.join("app/protocols").to_s
    config.autoload_paths   = config.autoload_paths.reject   { |p| p.to_s == protocols_root }
    config.eager_load_paths = config.eager_load_paths.reject { |p| p.to_s == protocols_root }

    initializer "rota_saude.protocols_namespace", after: :set_autoload_paths do
      Rails.autoloaders.main.push_dir(Rails.root.join("app/protocols").to_s, namespace: Protocols)
    end

    config.time_zone = "America/Sao_Paulo"
    config.i18n.default_locale = :"pt-BR"
    config.i18n.available_locales = [:"pt-BR", :en]
    config.i18n.enforce_available_locales = true
  end
end
