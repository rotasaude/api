# Troca o material de cifra de UMA cidade (Plano 7).
#
# Lê cada registro no contexto de ORIGEM e grava no de DESTINO. Não dá para usar
# `record.encrypt` (ReencryptionJob) porque ele lê e escreve no mesmo contexto, e
# o provedor determinístico aceita uma chave só — não existe janela de duas.
#
# A cidade deve estar SUSPENSA: entre ler e gravar, uma busca determinística de
# outro processo usaria a chave errada e não acharia a linha.
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

    CityConnection.with(@city) do
      TARGETS.each { |model, attribute| counts[model.name] += rewrite(model, attribute) }
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
          # AR's dirty-tracking never calls `changed_in_place?`, which would
          # otherwise decrypt the OLD (source-material) raw value to compare
          # it against the new plaintext — under THIS (destination) context,
          # which is exactly the wrong key for that ciphertext.
          record = model.unscoped.select(:id).find(id)
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
