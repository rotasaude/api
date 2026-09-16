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
class CityDeterministicKeyProvider
  def encryption_key
    provider.encryption_key
  end

  def decryption_keys(message = nil)
    provider.decryption_keys(message)
  end

  private

  # Um DeterministicKeyProvider por cidade, memoizado por material: derivar a cada
  # linha lida sairia caro numa consulta de muitas linhas. A chave de cache inclui
  # o material da cidade (encryption_key), não apenas o id, para que uma rotação de
  # chave não reutilize um provedor velho (isso seria lido silenciosamente com a
  # chave nova dados criptografados com a chave antiga).
  def provider
    city = Current.city
    raise CityEncryption::MissingKey, "atributo determinístico acessado fora de uma cidade" if city.nil?

    cache[cache_key(city)] ||= CityEncryption.deterministic_key_provider(city)
  end

  def cache_key(city) = [ city.id, city.encryption_key ].join(":")

  def cache
    Thread.current[:city_deterministic_key_providers] ||= {}
  end
end
