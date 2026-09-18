# Um salvamento de rascunho: quem editou a versão e qual conteúdo salvou
# (spec de assinaturas §5). Quem tem uma linha aqui nunca assina a versão.
# Só aceita acréscimo — o trigger rota_append_only recusa UPDATE e DELETE.
class ProtocolContribution < ApplicationRecord
  ACTOR_KINDS = %w[user maintainer].freeze

  belongs_to :protocol_definition

  validates :actor_id, :content_digest, presence: true
  validates :actor_kind, inclusion: { in: ACTOR_KINDS }

  def readonly? = persisted?
end
