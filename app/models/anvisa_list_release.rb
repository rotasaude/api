# app/models/anvisa_list_release.rb
# Uma importação das listas da Anvisa (ADR 0033): antimicrobianos (RDC 471) e
# controlados (Portaria 344, listas A1–C5), com a fonte de cada uma.
class AnvisaListRelease < PlatformRecord
  has_many :substances, class_name: "AnvisaListSubstance", foreign_key: :release_id, inverse_of: :release

  scope :active, -> { where(status: "active") }

  def self.current = active.order(activated_at: :desc).first
end
