# Grupo, oficina ou assembleia da grade semanal de um CAPS (ADR 0049): dia ISO
# (1 = segunda), horário, responsável, capacidade e o procedimento SIGTAP da
# ação que o grupo gera. Nunca é apagado (trigger); desativa-se.
class PsychosocialGroup < ApplicationRecord
  # starts_at/ends_at são hora do dia da cidade ("14:00"), não instantes: sem a
  # conversão de fuso do Rails (que gravaria 2000-01-01 em UTC, com o horário
  # de verão de 2000, e deslocaria a hora no banco).
  self.time_zone_aware_types = [ :datetime ]

  belongs_to :health_unit
  belongs_to :responsible_user, class_name: "User"
  belongs_to :updated_by_user, class_name: "User"
  has_many :psychosocial_actions, inverse_of: :psychosocial_group, dependent: :restrict_with_error
end
