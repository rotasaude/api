# Decisões do regulador sobre o pedido de regulação (contrato §4, §13 G5;
# papel `care_regulator`):
#   POST /regulation/requests/:id/authorize  { offer_id, color?, color_reason?, skip_reason?, version }
# Tudo só do corpo JSON (motivos nunca na URL nem no log). 200 com o
# <regulation_request> completo, com `events` (o dashboard aplica a resposta
# sem reler), e a trilha por pessoa, como o detalhe. Recusas `{ error, path? }`
# sem dado de outros pedidos (G5).
module CareRegulation
  class DecisionsController < BaseController
    AUTHORIZE_KEYS = %w[offer_id color color_reason skip_reason version].freeze
    KEY_PATH_MAX = 64

    before_action { forbid unless regulator? }
    before_action :load_request

    def authorize
      unknown = (body.keys - AUTHORIZE_KEYS).first
      return render(json: { error: "invalid_request", path: unknown.to_s[0, KEY_PATH_MAX] }, status: :unprocessable_entity) if unknown

      respond Authorize.call(request: @regulation_request, offer_id: body_param("offer_id"), version: body_param("version"),
                             by: Current.user, color: body_param("color"), color_reason: body_param("color_reason"),
                             skip_reason: body_param("skip_reason"))
    end

    private

    # Só pedido fora do rascunho (a fila); id malformado, desconhecido ou de
    # rascunho → 404.
    def load_request
      return unless query_only!

      @regulation_request = uuid?(params[:id]) ? RegulationRequest.where(status: Catalog::QUEUE_STATUSES).find_by(id: params[:id]) : nil
      not_found unless @regulation_request
    end

    def respond(result)
      return render_failure(result) if result.failure?

      saved = RegulationRequest.preload(Queue::PRELOAD, events: { by_user: :professional }).find(result.payload.fetch(:request).id)
      Trail.person_viewed!(user: Current.user, patient_id: saved.patient_id)
      render json: Json.request(saved, events: true, today: Time.zone.today)
    end
  end
end
