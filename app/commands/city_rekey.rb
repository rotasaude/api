# Troca o material de cifra de UMA cidade (Plano 7).
#
# Lê cada registro no contexto de ORIGEM e grava no de DESTINO. Não dá para usar
# `record.encrypt` (ReencryptionJob) porque ele lê e escreve no mesmo contexto, e
# o provedor determinístico aceita uma chave só — não existe janela de duas.
#
# A cidade deve estar SUSPENSA: entre ler e gravar, uma busca determinística de
# outro processo usaria a chave errada e não acharia a linha. Suspensão também é
# o que torna seguro fazer TUDO numa transação só (abaixo): sem escritores
# concorrentes, o custo do lock não compete com tráfego real.
#
# Tudo-ou-nada (fix round 1): a reescrita inteira roda dentro de UMA transação
# `ApplicationRecord.transaction` (não `ActiveRecord::Base.transaction` — essa
# abriria na conexão `primary`, que neste app é o banco vazio
# `rota_saude_no_city_selected`, não o da cidade; verificado comparando
# `ApplicationRecord.connection.current_database` dentro e fora do bloco).
# Uma falha no meio do caminho dá rollback: zero linhas mudam, e o
# `encryption_key` da cidade nunca precisa se mover para o valor novo antes de
# a reescrita ter, de fato, terminado. Isso também é por que um modo "resumível"
# (tentar a chave nova, cair para a antiga) foi rejeitado: colapsaria "já
# migrado" e "corrompido" no mesmo caminho, escondendo corrupção real como um
# resume qualquer.
#
# Fix round 2: a migração real de uma cidade em dev/produção NÃO é "chave de
# cidade A -> chave de cidade B" — é "chave da PLATAFORMA (o que já existia
# ANTES deste plano) -> chave da cidade". `source: :platform` cobre esse caso
# (confirmado ao vivo, só leitura, contra curitiba/maringa: Conversation#phone
# e InboundMessage#raw levantam Errors::Decryption sob o contexto de cidade
# hoje, e decifram sob a chave global). Nesse modo `from_key:` não se aplica —
# a origem já é a chave global, não um material arbitrário — e o lado da
# ESCRITA não muda: `to_key:` continua significando "material atual da
# cidade" quando nil. Ver `in_platform_source` para os dois mecanismos que a
# leitura em modo plataforma precisa (contexto para atributo não-determinístico,
# flag em Current para o determinístico).
class CityRekey
  BATCH_SIZE = 200

  # Só o que mora no banco DA CIDADE.
  TARGETS = [
    [ User,           :otp_secret ],
    [ Conversation,   :phone ],
    [ InboundMessage, :raw ],
    [ Consent,        :evidence ],
    [ Author,         :token ]
  ].freeze

  SOURCES = %i[city platform].freeze

  # Assinatura final (fix round 2): source: :city (padrão, comportamento das
  # rounds anteriores) ou source: :platform (migração pré-Plano-7 -> cidade).
  def self.call(city:, from_key: nil, to_key: nil, source: :city) =
    new(city: city, from_key: from_key, to_key: to_key, source: source).call

  def initialize(city:, from_key: nil, to_key: nil, source: :city)
    raise ArgumentError, "source: deve ser #{SOURCES.inspect}, recebeu #{source.inspect}" unless SOURCES.include?(source)
    if source == :platform && from_key
      raise ArgumentError, "from_key: não se combina com source: :platform — a origem já é a chave global"
    end

    @city = city
    @source = source
    @from_city = shadow_city(from_key)
    @to_city = shadow_city(to_key)
  end

  def call
    counts = Hash.new(0)

    # O rescue fica FORA da transação, de propósito: um raise dentro do bloco
    # desfaz o `ApplicationRecord.transaction` (rollback) antes de propagar até
    # aqui, então o Result.fail só é construído depois que o banco já voltou ao
    # estado anterior — nunca antes, nunca com a transação ainda aberta.
    CityConnection.with(@city) do
      ApplicationRecord.transaction do
        TARGETS.each { |model, attribute| counts[model.name] += rewrite(model, attribute) }
      end
    end

    Result.ok(counts: counts)
  rescue ActiveRecord::Encryption::Errors::Decryption
    Result.fail(:unreadable, message: "cidade #{@city.slug}: linha ilegível com o material de origem")
  end

  private

  # `from_key`/`to_key` nil = material atual da cidade. A cópia em memória existe
  # só para montar o provedor: nada dela é salvo.
  def shadow_city(material)
    return @city if material.blank?

    City.new(slug: @city.slug, name: @city.name, status: @city.status,
             database_url: @city.database_url, encryption_key: material)
  end

  def rewrite(model, attribute)
    count = 0

    model.unscoped.in_batches(of: BATCH_SIZE) do |batch|
      batch.pluck(:id).each do |id|
        plaintext = read_source(model, id, attribute)
        next if plaintext.nil?

        in_city(@to_city) do
          # `select(:id)` on purpose: the encrypted column stays unloaded, so
          # there is no original raw value in `@attributes` to compare the new
          # plaintext against. Without it, `save!` (via partial writes: AR
          # decides which columns changed through
          # `attribute_names_for_partial_updates` -> `changed_attribute_names_to_save`
          # -> `AttributeMutationTracker#changed?` -> `Attribute#changed_from_assignment?`
          # -> `#original_value` -> `FromDatabase#type_cast` ->
          # `EncryptedAttributeType#deserialize`) decrypts the OLD
          # (source-material) ciphertext under THIS (destination) context,
          # which is exactly the wrong key for it, and raises
          # `Errors::Decryption` on a row that is perfectly readable — a false
          # "unreadable", not a bug in the source data.
          #
          # `record_timestamps = false` (fix round 1) stops `save!` from
          # bumping `updated_at` — a full-city rekey must not make every row
          # look freshly touched (sweep/overview queries key off it). It does
          # NOT make `select(:id)` redundant: before this line existed, the
          # same decrypt-under-the-wrong-key crash came from a DIFFERENT call
          # site, `ActiveRecord::Timestamp#should_record_timestamps?` ->
          # `has_changes_to_save?` (same `changed_from_assignment?` chain).
          # Turning timestamps off closes that path but not the
          # partial-writes one above — verified experimentally: dropping
          # `select(:id)` while keeping `record_timestamps = false` still
          # raises `Errors::Decryption`, now via `attribute_names_for_partial_updates`.
          record = model.unscoped.select(:id).find(id)
          record.record_timestamps = false
          record.public_send("#{attribute}=", plaintext)
          record.save!(validate: false)
        end
        count += 1
      end
    end

    count
  end

  def read_source(model, id, attribute)
    if @source == :platform
      in_platform_source { model.unscoped.find(id).public_send(attribute) }
    else
      in_city(@from_city) { model.unscoped.find(id).public_send(attribute) }
    end
  end

  # Current.city governa o provedor determinístico; o contexto governa o resto.
  def in_city(city, &block)
    Current.set(city: city) do
      ActiveRecord::Encryption.with_encryption_context(**CityEncryption.context_properties(city), &block)
    end
  end

  # source: :platform — lê com a chave GLOBAL (a que dado pré-migração já usa),
  # não uma derivada de cidade nenhuma. Dois mecanismos, porque o Rails trata
  # atributo determinístico e não-determinístico de formas diferentes (ver
  # header de CityEncryption):
  #   1. Contexto de cifra (governa os NÃO-determinísticos, ex.:
  #      InboundMessage#raw, User#otp_secret, Consent#evidence):
  #      `PlatformKeyProvider.new` reusa exatamente o que
  #      app/services/platform_key_provider.rb já resolve
  #      (`ActiveRecord::Encryption.default_context.key_provider`) — a mesma
  #      chave que qualquer `encrypts` sem `key_provider:` usaria.
  #   2. Flag em `Current` (governa os DOIS determinísticos,
  #      Conversation#phone e Author#token): `key_provider:` no `encrypts`
  #      vence o contexto sempre, então não existe combinação de
  #      with_encryption_context que alcance esses atributos — só a flag que
  #      CityDeterministicKeyProvider consulta. `Current.set` desfaz a flag no
  #      `ensure`, mesmo se o bloco levantar, então ela nunca escapa deste
  #      bloco de leitura — nem para a escrita (in_city) a seguir, nem para
  #      fora de CityRekey inteiramente.
  def in_platform_source(&block)
    Current.set(deterministic_key_source: :platform) do
      ActiveRecord::Encryption.with_encryption_context(key_provider: PlatformKeyProvider.new, &block)
    end
  end
end
