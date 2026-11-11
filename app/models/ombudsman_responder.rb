# Respondente da ouvidoria (ADR 0051): o usuário que responde os encaminhamentos
# de um destino — um setor da secretaria ou uma unidade (CHECK: exatamente um).
# Único por (usuário, destino). Nunca é apagado (trigger): desliga-se.
class OmbudsmanResponder < ApplicationRecord
  belongs_to :user
  belongs_to :department, optional: true
  belongs_to :health_unit, optional: true
  belongs_to :created_by_user, class_name: "User"

  scope :active, -> { where(active: true) }

  def destination = department || health_unit
end
