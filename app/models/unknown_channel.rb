class UnknownChannel < ApplicationRecord
  def self.record!(phone_number_id:, change:)
    ApplicationRecord.connected_to(role: :admin) do
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
end
