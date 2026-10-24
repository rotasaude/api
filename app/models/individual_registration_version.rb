# Versão imutável do cadastro individual (módulo 24a, ADR 0042): só
# acréscimo; a re-cifra regrava só as colunas cifradas (trigger). As seções
# do dicionário (§15) são JSON cifrado com a chave da cidade (`serialize`
# ANTES de `encrypts`); a recusa é "true"/"false" cifrado.
class IndividualRegistrationVersion < ApplicationRecord
  SECTIONS = %i[identity identification sociodemographic health_conditions street_situation].freeze

  SECTIONS.each { |section| serialize section, coder: JSON }
  encrypts(*SECTIONS, :refused, :death_certificate)

  belongs_to :registration, class_name: "IndividualRegistration", inverse_of: :versions
  belongs_to :patient
  belongs_to :team, class_name: "HealthTeam"
  belongs_to :micro_area, optional: true
  belongs_to :household, optional: true
  belongs_to :family, optional: true
  belongs_to :saved_by_user, class_name: "User"
  belongs_to :saved_by_professional, class_name: "Professional"

  validates :origin, inclusion: { in: TerritoryRegistry::Catalog::VERSION_ORIGINS }
  validates :refused, inclusion: { in: %w[true false] }

  def refused? = refused == "true"

  def inspect = "#<IndividualRegistrationVersion id=#{id} registration_id=#{registration_id} version=#{version}>"
end
