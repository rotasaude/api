# Regras de Westgard ligadas por aparelho e analito (Desvio 3): versões só de
# acréscimo; vale a mais recente; sem linha = todas ligadas.
class LabQcRule < ApplicationRecord
  RULES = %w[1_2s 1_3s 2_2s R_4s 4_1s 10x].freeze

  belongs_to :lab_instrument
  belongs_to :changed_by_user, class_name: "User"

  def self.current_for(instrument_id, analyte_key)
    where(lab_instrument_id: instrument_id, analyte_key: analyte_key).order(:created_at, :id).last
  end

  def self.enabled_for(instrument_id, analyte_key)
    row = current_for(instrument_id, analyte_key)
    row ? RULES.select { |rule| row.rules[rule] == true } : RULES
  end
end
