# Canais desconhecidos (phone_number_id sem CityChannel correspondente), na
# PLATAFORMA — sem coluna de tenant, lido antes de saber a cidade.
class UnknownChannel < PlatformRecord
  def self.record!(phone_number_id:, change:)
    row = find_or_initialize_by(phone_number_id: phone_number_id)
    now = Time.current
    row.assign_attributes(
      sample_change: change.is_a?(Hash) ? change : { raw: change.to_s },
      hits: (row.hits || 0) + 1,
      first_seen_at: row.first_seen_at || now,
      last_seen_at: now
    )
    row.save!
    Platform.audit("channel.unknown_seen", phone_number_id: phone_number_id, hits: row.hits) if row.hits <= 3
    row
  end
end
