# Material de cifra de uma cidade (Plano 7, spec §6).
#
# A chave efetiva é DERIVADA de (chave da plataforma + cities.encryption_key):
# não há cofre novo, o segredo raiz continua sendo o da plataforma. O que a
# derivação compra é separação entre cidades; o que ela não compra é isolamento
# contra quem tem a chave da plataforma.
#
# Dois provedores, porque o Rails trata os casos de formas diferentes:
#   - não-determinístico: entra por contexto (CityConnection.with);
#   - determinístico: o Scheme resolve `DeterministicKeyProvider` direto de
#     config.deterministic_key e NUNCA olha o contexto — só o `key_provider:`
#     passado no `encrypts` vence isso (ver CityDeterministicKeyProvider).
module CityEncryption
  class MissingKey < StandardError; end

  # Os cinco atributos cifrados que moram no banco DA CIDADE e usam material
  # DERIVADO por cidade (via key_provider: CityDeterministicKeyProvider.new ou
  # a ausência de key_provider:, que cai no contexto de CityConnection.with) —
  # não os de plataforma, que ficam fixos em PlatformKeyProvider
  # (City#database_url, City#encryption_key, CityChannel#access_token,
  # Operator#otp_secret) e por isso nunca entram aqui.
  #
  # Fonte única (fix F6, rodada final de revisão): CityRekey::TARGETS
  # (migração/rotação, app/commands/city_rekey.rb) e ReencryptionJob::TARGETS
  # (re-cifra sob a chave atual, app/jobs/reencryption_job.rb) apontavam para
  # duas cópias literais desta mesma lista, mantidas em sincronia à mão. Os
  # dois agora apontam para ISTO, para que um `encrypts` novo não possa entrar
  # num registro e ficar esquecido no outro.
  CITY_KEYED_TARGETS = [
    [ User,           :otp_secret ],
    [ Conversation,   :phone ],
    [ InboundMessage, :raw ],
    [ Consent,        :evidence ],
    [ Author,         :token ]
  ].freeze

  module_function

  def context_properties(city)
    { key_provider: key_provider(city) }
  end

  def key_provider(city)
    ActiveRecord::Encryption::DerivedSecretKeyProvider.new([ secret_for(city, platform_primary_key) ])
  end

  def deterministic_key_provider(city)
    ActiveRecord::Encryption::DeterministicKeyProvider.new(secret_for(city, platform_deterministic_key))
  end

  # A chave determinística GLOBAL, sem derivar com material de cidade nenhuma
  # — a mesma que `Scheme#deterministic_key_provider` monta por baixo dos panos
  # quando um `encrypts ..., deterministic: true` não tem `key_provider:` (ver
  # Conversation#phone/Author#token ANTES deste plano). Existe para o rekey de
  # migração (CityRekey, source: :platform, Plano 7 fix round 2): dado
  # pré-migração foi cifrado com ISTO, não com nenhuma chave derivada por
  # cidade.
  def platform_deterministic_key_provider
    ActiveRecord::Encryption::DeterministicKeyProvider.new(platform_deterministic_key)
  end

  # Chave HMAC do token de relatório, por cidade (Plano 8, spec §6). Derivada da
  # chave global de assinatura + material da cidade: a custódia é a mesma da
  # chave de cifra, e um dump de A não permite forjar token de B.
  def report_signing_key(city)
    material = city.respond_to?(:encryption_key) ? city.encryption_key.to_s : ""
    raise MissingKey, "cidade sem encryption_key: não há chave a derivar" if material.blank?

    OpenSSL::HMAC.digest("sha256", legacy_report_signing_key, "report-signing:#{material}")
  end

  # `fetch` de propósito (nunca `[]`): assinatura com chave nil é assinatura que
  # confere contra qualquer coisa. Mas o KeyError cru escapava de todo `rescue
  # MissingKey` rio acima — e como report_signing_key/1 passa por aqui, isso
  # valia para TODA assinatura por cidade, não só pela legada. O chamador que
  # mais sofria era city:rotate_key, cujo ramo de re-sign roda depois de os
  # dados já terem sido reescritos: ali o operador precisa da instrução de
  # recuperação, não de um backtrace.
  def legacy_report_signing_key
    Rails.application.credentials.fetch(:report_signing_key)
  rescue KeyError
    raise MissingKey, "credencial :report_signing_key ausente — não há chave de assinatura de relatório a derivar"
  end

  def secret_for(city, platform_secret)
    material = city.respond_to?(:encryption_key) ? city.encryption_key.to_s : ""
    raise MissingKey, "cidade sem encryption_key: não há chave a derivar" if material.blank?
    raise MissingKey, "chave de plataforma ausente" if platform_secret.to_s.blank?

    "#{platform_secret}:#{material}"
  end

  def platform_primary_key = Rails.application.config.active_record.encryption.primary_key
  def platform_deterministic_key = Rails.application.config.active_record.encryption.deterministic_key

  private_class_method :secret_for, :platform_primary_key, :platform_deterministic_key
end
