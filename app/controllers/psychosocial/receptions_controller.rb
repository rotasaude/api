# POST /psychosocial/receptions (ADR 0049; contrato §4, P7, P33): acolhimento
# no CAPS lotado (Psychosocial::RecordReception) → 201
# `{ reception_id, enrollment_id | null }`. Encaminhamento já usado → 409
# referral_not_pending. Paciente e texto só no corpo.
module Psychosocial
  class ReceptionsController < BaseController
    def create
      return unless query_only!

      unit = staff_unit!(body_param("health_unit_id"))
      return unless unit

      result = RecordReception.call(attrs: body, unit: unit, by: Current.user, link: @link)
      return render_failure(result) if result.failure?

      render json: { reception_id: result.payload.fetch(:reception).id, enrollment_id: result.payload[:enrollment]&.id },
             status: :created
    end
  end
end
