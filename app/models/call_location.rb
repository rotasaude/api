# Local de chamada da unidade (ADR 0050; contrato §8): "Consultório 1",
# "Classificação". Nome único por unidade sem diferença de caixa; desativado,
# nunca apagado (trigger).
class CallLocation < ApplicationRecord
  belongs_to :health_unit
  belongs_to :updated_by_user, class_name: "User"

  scope :active, -> { where(active: true) }
end
