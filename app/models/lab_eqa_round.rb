# Rodada do controle externo (CEQ; ADR 0038): só acréscimo.
class LabEqaRound < ApplicationRecord
  ADEQUACY = %w[adequate inadequate].freeze

  belongs_to :exam_provider
  belongs_to :recorded_by_user, class_name: "User"
end
