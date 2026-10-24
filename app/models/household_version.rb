# Versão imutável do domicílio (módulo 24a, ADR 0042): só acréscimo; a
# re-cifra regrava só as colunas cifradas (trigger). Endereço, condições de
# moradia e o retrato das famílias são JSON cifrado com a chave da cidade
# (`serialize` ANTES de `encrypts`); a recusa é "true"/"false" cifrado.
class HouseholdVersion < ApplicationRecord
  ORIGINS = %w[save].freeze

  serialize :address, coder: JSON
  serialize :living_conditions, coder: JSON
  serialize :families_snapshot, coder: JSON
  encrypts :address, :living_conditions, :contact_phone, :refused, :families_snapshot

  belongs_to :household
  belongs_to :micro_area
  belongs_to :team, class_name: "HealthTeam"
  belongs_to :neighborhood, optional: true
  belongs_to :saved_by_user, class_name: "User"
  belongs_to :saved_by_professional, class_name: "Professional"

  validates :property_type, inclusion: { in: TerritoryRegistry::Catalog::PROPERTY_TYPES }
  validates :status, inclusion: { in: Household::STATUSES }
  validates :origin, inclusion: { in: ORIGINS }
  validates :refused, inclusion: { in: %w[true false] }

  def refused? = refused == "true"

  def inspect = "#<HouseholdVersion id=#{id} household_id=#{household_id} version=#{version}>"
end
