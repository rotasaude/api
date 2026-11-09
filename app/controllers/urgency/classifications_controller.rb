# POST /urgency/encounters/:id/classifications { complaint, vital_signs,
# pain_scale, color, justification? } (contrato §5, §14 Q2, Q3, Q6, Q22): a
# classificação de risco ou a reclassificação pelo Urgency::Classify (só a
# enfermagem 2235 com vínculo na UPA). → 201 `{ encounter: <detalhe>,
# suggested: { color, criterion } | null }`, com a trilha do encontro. Tudo só
# do corpo: nada na query.
module Urgency
  class ClassificationsController < BaseController
    def create
      return unless query_only!

      encounter = find_encounter(params[:id])
      return unless encounter

      result = Classify.call(encounter: encounter, attrs: body, by: Current.user)
      return render_failure(result) if result.failure?

      suggested = result.payload[:suggested]&.slice(:color, :criterion)
      render_encounter(encounter.reload, clinical: true, status: :created, suggested: suggested)
    end
  end
end
