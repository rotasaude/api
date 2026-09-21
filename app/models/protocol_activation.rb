# Um ato de ativação (spec de assinaturas §5, §6). A última linha de uma versão
# marca até quando as assinaturas de ativação dela já foram consumidas, e a
# sequência por protocolo é o que a reversão de emergência lê. Três tipos:
# `signed` e `emergency_revert` (atos de verdade, sempre com ator humano) e
# `baseline` — uma versão que já estava em uso antes das assinaturas (Task 1,
# fatia 2), que só pode ser ALVO de uma reversão, nunca origem. Só aceita
# acréscimo.
class ProtocolActivation < ApplicationRecord
  KINDS = %w[signed emergency_revert baseline].freeze
  # `system` só existe para a linha-base, criada pela migração e pelo seed de
  # dev — nenhum command cria uma.
  ACTOR_KINDS = %w[user maintainer system].freeze

  belongs_to :protocol_definition

  validates :kind, inclusion: { in: KINDS }
  validates :actor_kind, inclusion: { in: ACTOR_KINDS }
  validates :actor_id, presence: true, unless: -> { kind == "baseline" }
  validates :actor_id, absence: true, if: -> { kind == "baseline" }
  validates :reason, presence: true, if: -> { kind == "emergency_revert" }

  def readonly? = persisted?
end
