# Um grant de entrada numa cidade, no banco de PLATAFORMA. Ver CityGrants.
class CityGrant < PlatformRecord
  KINDS = %w[operator user].freeze

  belongs_to :city

  validates :kind, inclusion: { in: KINDS }
  validates :subject_id, :expires_at, presence: true
end
