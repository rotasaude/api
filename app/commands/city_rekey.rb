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

  def self.call(city:, from_key: nil, to_key: nil) = new(city: city, from_key: from_key, to_key: to_key).call

  def initialize(city:, from_key: nil, to_key: nil)
    @city = city
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
        plaintext = in_city(@from_city) { model.unscoped.find(id).public_send(attribute) }
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

  # Current.city governa o provedor determinístico; o contexto governa o resto.
  def in_city(city, &block)
    Current.set(city: city) do
      ActiveRecord::Encryption.with_encryption_context(**CityEncryption.context_properties(city), &block)
    end
  end
end
