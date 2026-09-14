# Canais desconhecidos (phone_number_id sem CityChannel correspondente), na
# PLATAFORMA — sem coluna de tenant, lido antes de saber a cidade.
#
# INVARIANTE: a plataforma nunca guarda dado de cidadão (ver PlatformRecord).
# `sample_change` guarda só metadado de roteamento (para diagnosticar qual
# WABA está mal configurado) — nunca `messages`, `contacts`, `statuses`,
# `errors`, nem qualquer `from`/`wa_id`/telefone/texto, em qualquer
# profundidade. Construído por allow-list (escolhe as chaves permitidas), não
# deny-list (apagaria as perigosas) — um deny-list vaza silenciosamente
# qualquer campo novo que a Meta adicionar.
class UnknownChannel < PlatformRecord
  ALLOWED_VALUE_KEYS = %w[messaging_product].freeze
  ALLOWED_METADATA_KEYS = %w[phone_number_id display_phone_number].freeze

  def self.record!(phone_number_id:, change:)
    row = find_or_initialize_by(phone_number_id: phone_number_id)
    now = Time.current
    row.assign_attributes(
      sample_change: redact(change),
      hits: (row.hits || 0) + 1,
      first_seen_at: row.first_seen_at || now,
      last_seen_at: now
    )
    row.save!
    Platform.audit("channel.unknown_seen", phone_number_id: phone_number_id, hits: row.hits) if row.hits <= 3
    row
  end

  def self.redact(change)
    return {} unless change.is_a?(Hash)

    value = change["value"]
    value = {} unless value.is_a?(Hash)
    metadata = value["metadata"]
    metadata = {} unless metadata.is_a?(Hash)

    {}.tap do |redacted|
      redacted["field"] = change["field"] if change.key?("field")
      ALLOWED_VALUE_KEYS.each { |k| redacted[k] = value[k] if value.key?(k) }
      ALLOWED_METADATA_KEYS.each { |k| redacted[k] = metadata[k] if metadata.key?(k) }
    end
  end
  private_class_method :redact
end
