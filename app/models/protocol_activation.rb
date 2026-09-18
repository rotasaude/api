# Um ato de ativação (spec de assinaturas §5, §6). A última linha de uma versão
# marca até quando as assinaturas de ativação dela já foram consumidas, e a
# sequência por protocolo é o que a reversão de emergência lê. Só aceita
# acréscimo.
class ProtocolActivation < ApplicationRecord
  KINDS = %w[signed emergency_revert].freeze

  belongs_to :protocol_definition

  validates :actor_id, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :actor_kind, inclusion: { in: ProtocolContribution::ACTOR_KINDS }
  validates :reason, presence: true, if: -> { kind == "emergency_revert" }

  def readonly? = persisted?
end
