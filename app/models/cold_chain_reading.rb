# Leitura de temperatura do equipamento (atual, mínima e máxima). Só acréscimo
# (trigger).
class ColdChainReading < ApplicationRecord
  belongs_to :cold_chain_equipment, inverse_of: :readings
  belongs_to :recorded_by_user, class_name: "User"
  has_one :excursion, class_name: "ColdChainExcursion", inverse_of: :cold_chain_reading
end
