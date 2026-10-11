# Predicados de ambiente que valem para a aplicação inteira (spec da API de
# manutenção §4).
#
# Fica em lib/ e é `require`ado por config/application.rb, não autoloaded:
# config/application.rb e config/environments/*.rb rodam antes do Zeitwerk, e
# ambos perguntam Rota.deployed? (mesmo motivo de lib/platform_hosts.rb).
require "ipaddr"
require "action_dispatch/middleware/remote_ip"

module Rota
  # Ambientes publicados em infraestrutura compartilhada. staging é ensaio de
  # produção: tudo que endurece produção — cookie Secure, TLS no banco da cidade,
  # env var obrigatória, HostAuthorization — vale igual lá. Perguntar
  # `Rails.env.production?` com esse sentido deixaria staging sem essas proteções
  # sem aviso nenhum; spec/architecture/deployed_environment_guard_spec.rb proíbe.
  DEPLOYED_ENVS = %w[production staging].freeze

  # Ambientes que exigem config/credentials/<env>.yml.enc. Sem esse arquivo o Rails
  # cai, em silêncio, em config/credentials.yml.enc — as chaves de outro ambiente.
  # production entrou no fechamento do módulo 06 (decisão do usuário): sem
  # config/credentials/production.yml.enc o boot de produção FALHA — criar o
  # arquivo e guardar production.key no cofre está em deploy/SECRETS.md.
  ISOLATED_CREDENTIALS_ENVS = %w[staging production].freeze

  class SharedCredentials < StandardError; end
  class InvalidTrustedProxies < StandardError; end

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

  # Card api#62: os rate_limit do api contam por `request.remote_ip`. Atrás do
  # proxy de borda da cidade + kamal-proxy, sem saber quem é proxy o Rails vê o
  # IP do proxy (todos os cidadãos dividem um balde) ou aceita um
  # X-Forwarded-For forjado. TRUSTED_PROXIES lista os CIDRs desses proxies,
  # separados por vírgula e/ou espaço (IP único ou CIDR, IPv4 ou IPv6).
  #
  # Soma-se aos padrões do Rails (loopback e redes privadas): o kamal-proxy fala
  # com o container por rede docker privada, e atribuir uma lista própria
  # SUBSTITUIRIA esses padrões. Devolve nil quando não configurado — quem chama
  # decide (em production/staging, só avisa). Valor inválido levanta: engolir
  # deixaria o limite por IP errado em silêncio.
  def trusted_proxies(value)
    entries = value.to_s.split(/[,\s]+/).reject(&:empty?)
    return nil if entries.empty?

    parsed = entries.map do |entry|
      ip = begin
        IPAddr.new(entry)
      rescue IPAddr::Error
        raise InvalidTrustedProxies, "TRUSTED_PROXIES tem a entrada inválida #{entry.inspect} — use IP ou CIDR " \
                                     "(IPv4 ou IPv6) separados por vírgula, ex.: 203.0.113.10/32,2001:db8::/32"
      end
      # Prefixo 0 cobre a família inteira (0.0.0.0/0, ::/0, mesmo escrito com host bits).
      if ip.prefix.zero?
        raise InvalidTrustedProxies, "TRUSTED_PROXIES tem a entrada #{entry.inspect}, que cobre todos os endereços: " \
                                     "confiar em tudo anula o limite por IP (todo X-Forwarded-For passaria a valer). " \
                                     "Liste só os CIDRs dos proxies de borda."
      end
      ip
    end
    ActionDispatch::RemoteIp::TRUSTED_PROXIES + parsed
  end

  # Ausência de TRUSTED_PROXIES em ambiente publicado só avisa (decisão do
  # usuário): derrubar o boot travaria o deploy por um valor ainda desconhecido
  # (gate de go-live). O aviso deixa o efeito explícito no log.
  def warn_missing_trusted_proxies(env: Rails.env, value: ENV["TRUSTED_PROXIES"], logger: Rails.logger)
    return unless deployed?(env)
    return unless value.to_s.strip.empty?

    logger.warn "TRUSTED_PROXIES não está definida em #{env}: o limite por IP (rate_limit) vê o IP do proxy de " \
                "borda, não o do cidadão — todos os cidadãos dividem um único balde de limite. " \
                "Defina os CIDRs dos proxies (deploy/SECRETS.md)."
  end
end
