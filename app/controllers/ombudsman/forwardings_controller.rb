# POST /ombudsman/forwardings/:id/cancel { expected_state, reason? } (ADR 0051;
# contrato §2, §5; §16 Q32, Q33): técnico ou ouvidor cancelam um
# encaminhamento `pending` (Ombudsman::CancelForwarding). `expected_state` é o
# do encaminhamento (409 forwarding_changed). Sucesso → 200 com o detalhe da
# manifestação (Q32). Corpo só com as chaves da rota, nada na query (422 com o
# nome da chave); id malformado ou inexistente → 404.
module Ombudsman
  class ForwardingsController < BaseController
    KEYS = %w[expected_state reason].freeze

    before_action :require_staff!
    before_action -> { body_keys!(KEYS) }
    before_action :uuid_id!

    def cancel
      result = CancelForwarding.call(forwarding_id: params[:id], expected_state: body_param("expected_state"),
                                     reason: body_param("reason"), by: Current.user)
      return render_failure(result) if result.failure?

      render_detail(result.payload.fetch(:manifestation).id)
    end
  end
end
