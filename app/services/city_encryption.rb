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

  def secret_for(city, platform_secret)
    material = city.respond_to?(:encryption_key) ? city.encryption_key.to_s : ""
    raise MissingKey, "cidade sem encryption_key: não há chave a derivar" if material.blank?
    raise MissingKey, "chave de plataforma ausente" if platform_secret.to_s.blank?

    "#{platform_secret}:#{material}"
  end

  def platform_primary_key = Rails.application.config.active_record.encryption.primary_key
  def platform_deterministic_key = Rails.application.config.active_record.encryption.deterministic_key
end
