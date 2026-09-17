# Predicados de ambiente que valem para a aplicação inteira (spec da API de
# manutenção §4).
#
# Fica em lib/ e é `require`ado por config/application.rb, não autoloaded:
# config/application.rb e config/environments/*.rb rodam antes do Zeitwerk, e
# ambos perguntam Rota.deployed? (mesmo motivo de lib/platform_hosts.rb).
module Rota
  # Ambientes publicados em infraestrutura compartilhada. staging é ensaio de
  # produção: tudo que endurece produção — cookie Secure, TLS no banco da cidade,
  # env var obrigatória, HostAuthorization — vale igual lá. Perguntar
  # `Rails.env.production?` com esse sentido deixaria staging sem essas proteções
  # sem aviso nenhum; spec/architecture/deployed_environment_guard_spec.rb proíbe.
  DEPLOYED_ENVS = %w[production staging].freeze

  # Ambientes que exigem config/credentials/<env>.yml.enc. Sem esse arquivo o Rails
  # cai, em silêncio, em config/credentials.yml.enc — as chaves de outro ambiente.
  # production entra aqui quando ganhar o arquivo próprio.
  ISOLATED_CREDENTIALS_ENVS = %w[staging].freeze

  class SharedCredentials < StandardError; end

  module_function

  def deployed?(env = Rails.env)
    DEPLOYED_ENVS.include?(env.to_s)
  end

  def check_credentials!(env: Rails.env, content_path: Rails.application.config.credentials.content_path)
    return unless ISOLATED_CREDENTIALS_ENVS.include?(env.to_s)

    expected = "#{env}.yml.enc"
    return if Pathname(content_path.to_s).basename.to_s == expected

    raise SharedCredentials, "#{env} está lendo #{Pathname(content_path.to_s).basename} — precisa de " \
                             "config/credentials/#{expected} com chaves próprias (isolamento entre ambientes)"
  end
end
