# Perfil do imóvel na vigilância ambiental (módulo 35a; contrato §1; Q2): 1:1
# com o domicílio do 24a. Quarteirão (nulo até alguém atribuir), risco com a
# data juntos (CHECK) e o último trabalho, denormalizado pelo boletim (§3).
# Não é versão do 24a: mudar quarteirão ou risco não cria household_versions
# nem ficha LEDI. Nunca apagado (trigger).
class HouseholdVectorProfile < ApplicationRecord
  belongs_to :household
  belongs_to :city_block, optional: true
  belongs_to :updated_by_user, class_name: "User", optional: true

  validates :risk_class, inclusion: { in: VectorControl::Catalog::RISK_CLASSES }, allow_nil: true
  validates :last_situation, inclusion: { in: VectorControl::Catalog::SITUATIONS }, allow_nil: true

  def inspect = "#<HouseholdVectorProfile id=#{id} household_id=#{household_id} version=#{version}>"
end
