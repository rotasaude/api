# Decisões do regulador sobre o pedido de regulação (contrato §4, §13 G5;
# papel `care_regulator`):
#   POST /regulation/requests/:id/authorize  { offer_id, color?, color_reason?, skip_reason?, version }
#   POST /regulation/requests/:id/return     { reason, version }
#   POST /regulation/requests/:id/deny       { reason, version }
#   POST /regulation/requests/:id/cancel     { reason, version }
# e, da unidade solicitante (`health_professional`, contrato §5):
#   POST /regulation/requests/:id/complement { justification, cid10?, ciap2?, suggested_color?, version }
# Tudo só do corpo JSON (motivos nunca na URL nem no log). 200 com o
# <regulation_request> completo, com `events` (o dashboard aplica a resposta
# sem reler), e a trilha por pessoa, como o detalhe. Recusas `{ error, path? }`
# sem dado de outros pedidos (G5).
module CareRegulation
  class DecisionsController < BaseController
    AUTHORIZE_KEYS = %w[offer_id color color_reason skip_reason version].freeze
    DECISION_KEYS = %w[reason version].freeze
    COMPLEMENT_KEYS = (Complement::KEYS + %w[version]).freeze
    KEY_PATH_MAX = 64

    # O complemento é da unidade solicitante: o Complement confere o vínculo
    # na unidade (outra unidade: 404 not_found, registro de outro escopo) e o
    # CBO (403 cbo_not_allowed).
    before_action(except: :complement) { forbid unless regulator? }
    before_action(only: :complement) { forbid unless Current.user.has_role?("health_professional") }
    before_action :load_request

    def authorize
      return if unknown_key!(AUTHORIZE_KEYS)

      respond Authorize.call(request: @regulation_request, offer_id: body_param("offer_id"), version: body_param("version"),
                             by: Current.user, color: body_param("color"), color_reason: body_param("color_reason"),
                             skip_reason: body_param("skip_reason"))
    end

    def return_request = decide("return")
    def deny = decide("deny")
    def cancel = decide("cancel")

    def complement
      return if unknown_key!(COMPLEMENT_KEYS)

      respond Complement.call(request: @regulation_request, attrs: body.slice(*Complement::KEYS), version: body_param("version"),
                              by: Current.user)
    end

    private

    def decide(decision)
      return if unknown_key!(DECISION_KEYS)

      respond Decide.call(request: @regulation_request, decision: decision, reason: body_param("reason"),
                          version: body_param("version"), by: Current.user)
    end

    # Chave fora de `allowed` → 422 invalid_request com o path (truncado);
    # true depois de responder.
    def unknown_key!(allowed)
      unknown = (body.keys - allowed).first
      return false unless unknown

      render(json: { error: "invalid_request", path: unknown.to_s[0, KEY_PATH_MAX] }, status: :unprocessable_entity)
      true
    end

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
