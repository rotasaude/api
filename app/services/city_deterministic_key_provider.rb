# Provedor de chave DETERMINÍSTICA por cidade (Plano 7).
#
# Por que existe: para atributo determinístico, o Scheme do Rails monta
# `DeterministicKeyProvider.new(config.deterministic_key)` e nunca consulta o
# contexto de cifra — trocar contexto em CityConnection.with não alcança
# `Conversation#phone` nem `Author#token`. O único ponto que vence essa
# resolução é o `key_provider:` do próprio `encrypts`, e ele é avaliado UMA vez,
# na carga da classe. Por isso o provedor é declarado uma vez e resolve a chave
# a cada chamada, a partir de Current.city.
#
# Consequência: toda leitura e escrita desses atributos precisa acontecer com
# Current.city setado. CityConnection.with passou a garantir isso (Plano 7).
#
# Fix round 2: `Current.deterministic_key_source == :platform` é uma segunda
# saída, além de Current.city — dado pré-migração foi cifrado com a chave
# determinística GLOBAL, não com nenhuma derivada de cidade, e é isso que
# CityRekey (source: :platform) precisa ler. A flag vence Current.city: com
# ela ligada, nem olhamos a cidade corrente. Com ela desligada (o padrão,
# nil), nada muda — inclusive falhar fechado com MissingKey fora de uma
# cidade continua idêntico.
class CityDeterministicKeyProvider
  def encryption_key
    provider.encryption_key
  end

  # Sem default para `message` (fix da rodada final de revisão): a base
  # `ActiveRecord::Encryption::KeyProvider#decryption_keys` do Rails não tem
  # um — inventar `= nil` aqui só trocaria um `ArgumentError` imediato (chamador
  # esqueceu o argumento) por um `NoMethodError` bem mais fundo, em
  # `nil.headers` dentro do gem, na hora de decifrar.
  def decryption_keys(message)
    provider.decryption_keys(message)
  end

  private

  # Um DeterministicKeyProvider por cidade, memoizado por material: derivar a cada
  # linha lida sairia caro numa consulta de muitas linhas. A chave de cache inclui
  # o material da cidade (encryption_key), não apenas o id, para que uma rotação de
  # chave não reutilize um provedor velho (isso seria lido silenciosamente com a
  # chave nova dados criptografados com a chave antiga).
  #
  # A entrada do provider GLOBAL (`cache[:platform]`) usa uma chave Symbol,
  # nunca colidindo com `cache_key(city)` (sempre uma String "id:material"): os
  # dois tipos nunca são `==` entre si, então não há como o provider errado
  # sair do cache em nenhuma direção, mesmo que id/material algum dia
  # coincidisse textualmente com "platform".
  def provider
    if Current.deterministic_key_source == :platform
      cache[:platform] ||= CityEncryption.platform_deterministic_key_provider
    else
      city = Current.city
      raise CityEncryption::MissingKey, "atributo determinístico acessado fora de uma cidade" if city.nil?

      cache[cache_key(city)] ||= CityEncryption.deterministic_key_provider(city)
    end
  end

  def cache_key(city) = [ city.id, city.encryption_key ].join(":")

  def cache
    Thread.current[:city_deterministic_key_providers] ||= {}
  end
end
