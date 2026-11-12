# Decisão do pedido de reabertura do cidadão (ADR 0051; contrato §2; §16 Q8,
# Q32): só o ouvidor.
#   POST /ombudsman/reopen_requests/:id/decide { decision: accept | reject, text }
# Sucesso → 200 com o detalhe atualizado da manifestação; já decidido → 409
# already_decided; id malformado ou inexistente → 404. Corpo só com
# decision/text e nada na query (422 com o nome da chave).
module Ombudsman
  class ReopenRequestsController < BaseController
    KEYS = %w[decision text].freeze

    before_action :require_ombudsman_role!
    before_action -> { body_keys!(KEYS) }
    before_action :uuid_id!

    def decide
      result = DecideReopen.call(request_id: params[:id], decision: body_param("decision"), text: body_param("text"), by: Current.user)
      return render_failure(result) if result.failure?

      render_detail(result.payload.fetch(:manifestation).id)
    end
  end
end
