# A ÚNICA resposta para "esta versão tem as assinaturas?" (spec de assinaturas
# §5). Publish e Activate perguntam aqui, no momento do ato — nunca antes —,
# porque as condições mudam depois da assinatura: o conteúdo pode ser editado,
# o revisor pode perder o papel, quem assinou pode passar a editar.
#
# Uma assinatura conta quando, AGORA:
#   1. a finalidade é a do ato;
#   2. o digest é o do conteúdo atual;
#   3. o signatário ainda tem protocol_reviewer ativo e não foi desativado;
#   4. o signatário nunca contribuiu para a versão;
#   5. (ativação) é posterior à última ativação da versão — o ato consome as
#      assinaturas sem alterar nenhuma linha.
module Protocols
  module Signatures
    REQUIRED = 2
    PURPOSE_LABELS = { "publication" => "publicação", "activation" => "ativação" }.freeze

    module_function

    def valid_signer_ids(protocol, purpose:)
      scope = ProtocolSignature.where(protocol_definition_id: protocol.id, purpose: purpose,
                                      content_digest: protocol.content_digest)
                               .where(signer_user_id: active_reviewer_ids)
                               .where.not(signer_user_id: contributor_ids(protocol))

      if purpose == "activation"
        last_activation = ProtocolActivation.where(protocol_definition_id: protocol.id).maximum(:created_at)
        scope = scope.where("protocol_signatures.created_at > ?", last_activation) if last_activation
      end

      scope.distinct.pluck(:signer_user_id)
    end

    def missing(protocol, purpose:)
      [ REQUIRED - valid_signer_ids(protocol, purpose: purpose).size, 0 ].max
    end

    def eligible_reviewer_count(protocol)
      User.where(id: active_reviewer_ids).where.not(id: contributor_ids(protocol)).count
    end

    def shortfall_message(protocol, purpose:)
      count = missing(protocol, purpose: purpose)
      falta = count == 1 ? "falta 1 assinatura" : "faltam #{count} assinaturas"
      "#{falta} de #{PURPOSE_LABELS.fetch(purpose)}; revisores elegíveis na cidade: #{eligible_reviewer_count(protocol)}"
    end

    def active_reviewer_ids
      Membership.active.where(role: "protocol_reviewer")
                .joins(:user).where(users: { deactivated_at: nil })
                .select(:user_id)
    end

    def contributor_ids(protocol)
      ProtocolContribution.where(protocol_definition_id: protocol.id, actor_kind: "user").select(:actor_id)
    end
  end
end
