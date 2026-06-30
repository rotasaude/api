require_relative "boot"

require "rails/all"

Bundler.require(*Rails.groups)

# Pré-declara Protocols para Zeitwerk usar como namespace de app/protocols/
# em vez de torná-la um root top-level. Sem isso, app/protocols/validator.rb
# carregaria como `Validator`, não `Protocols::Validator`. Ver ADR-0013.
module Protocols
end

# Pré-declara Messaging para Zeitwerk usar como namespace de app/messaging/
# em vez de torná-la um root top-level. Sem isso, app/messaging/reply.rb
# carregaria como `Reply`, não `Messaging::Reply`. Ver F-03.3.
module Messaging
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

    # Remove app/protocols/ e app/messaging/ dos roots default e re-registra
    # com namespace. Rails 8 adiciona automaticamente todos os app/<subdir>
    # como roots — sem essa remoção, os arquivos dentro seriam constantes
    # top-level (e.g. Reply em vez de Messaging::Reply).
    protocols_root = Rails.root.join("app/protocols").to_s
    messaging_root = Rails.root.join("app/messaging").to_s
    config.autoload_paths   = config.autoload_paths.reject   { |p| [protocols_root, messaging_root].include?(p.to_s) }
    config.eager_load_paths = config.eager_load_paths.reject { |p| [protocols_root, messaging_root].include?(p.to_s) }

    initializer "rota_saude.protocols_namespace", after: :set_autoload_paths do
      Rails.autoloaders.main.push_dir(Rails.root.join("app/protocols").to_s, namespace: Protocols)
      Rails.autoloaders.main.push_dir(Rails.root.join("app/messaging").to_s, namespace: Messaging)
    end

    config.time_zone = "America/Sao_Paulo"
    config.i18n.default_locale = :"pt-BR"
    config.i18n.available_locales = [:"pt-BR", :en]
    config.i18n.enforce_available_locales = true
  end
end
