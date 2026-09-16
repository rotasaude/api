# Provedor de chave da PLATAFORMA, para atributos cifrados que vivem no banco
# de plataforma mesmo quando são lidos/escritos de DENTRO de
# CityConnection.with (Plano 7).
#
# Por que existe: ActiveRecord::Encryption.with_encryption_context é por
# thread e GLOBAL, não por model — o contexto de cifra que CityConnection.with
# instala para os atributos da cidade (Conversation#phone, InboundMessage#raw)
# também vale para qualquer atributo cifrado avaliado dentro do bloco, mesmo
# que pertença à plataforma. City#database_url, City#encryption_key,
# CityChannel#access_token e Operator#otp_secret são lidos/escritos de dentro
# de CityConnection.with na prática (ex.: SendWhatsappJob lê
# CityChannel#access_token rodando já na conexão da cidade) — sem fixar o
# key_provider, essas leituras tentam decifrar com a chave derivada da cidade
# e levantam ActiveRecord::Encryption::Errors::Decryption; escritas gravariam
# dado de plataforma cifrado com a chave errada, silenciosamente.
#
# `default_context` é o Context que o Rails cria uma vez, a partir de
# config.active_record.encryption, e NUNCA é substituído por
# with_encryption_context (que empilha um Context em cima, custom_contexts,
# e desempilha no ensure) — por isso ele continua servindo a mesma chave de
# sempre mesmo dentro do bloco da cidade. Resolvido a cada chamada (não
# memoizado aqui) para não fixar nada antes do boot terminar; o próprio Rails
# já memoiza o key_provider do contexto padrão internamente
# (Context#key_provider), então isto não deriva a chave duas vezes.
class PlatformKeyProvider
  def encryption_key
    provider.encryption_key
  end

  # Sem default para `message` (mesma correção de CityDeterministicKeyProvider,
  # rodada final de revisão) — a base do Rails não tem um, e `= nil` só troca
  # um ArgumentError imediato por um NoMethodError mais fundo dentro do gem.
  def decryption_keys(message)
    provider.decryption_keys(message)
  end

  private

  def provider
    ActiveRecord::Encryption.default_context.key_provider
  end
end
