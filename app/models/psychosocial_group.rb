# Grupo, oficina ou assembleia da grade semanal de um CAPS (ADR 0049): dia ISO
# (1 = segunda), horário, responsável, capacidade e o procedimento SIGTAP da
# ação que o grupo gera. Nunca é apagado (trigger); desativa-se.
class PsychosocialGroup < ApplicationRecord
  belongs_to :health_unit
  belongs_to :responsible_user, class_name: "User"
  belongs_to :updated_by_user, class_name: "User"
  has_many :psychosocial_actions, inverse_of: :psychosocial_group, dependent: :restrict_with_error
end
