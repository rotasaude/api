# POST /urgency/suggest { encounter_id, complaint?, vital_signs, pain_scale }
# (contrato §5, §14 Q1, Q3): a prévia da cor pelo protocolo ativo, com a
# idade e o sexo do paciente do encontro. Não grava nada e não grava trilha.
# A queixa é aceita e ignorada (nunca entra na condição); `pain_scale` nulo →
# `suggested: null` (sem cor antes da dor avaliada). → 200 `{ suggested:
# { color, criterion, rule_id } | null, levels: [ { color, max_wait_minutes } ] }`,
# os níveis do protocolo ativo (ou o padrão) na ordem das cores. Só quem
# classifica (2235 com vínculo na UPA do encontro). Sem `encounter_id` → 422
# invalid_request `path: "encounter_id"`; id desconhecido → 404.
module Urgency
  class SuggestionsController < BaseController
    ALLOWED = %w[encounter_id complaint vital_signs pain_scale].freeze

    def create
      return unless query_only!

      unknown = (body.keys - ALLOWED).first
      return render_refusal(unknown.to_s[0, KEY_PATH_MAX]) if unknown

      return render_refusal("encounter_id") if body_param("encounter_id").blank?

      encounter = find_encounter(body_param("encounter_id"))
      return unless encounter

      access = Access.classifier(Current.user, encounter.attendance.health_unit_id)
      return render_failure(access) if access.failure?

      vitals = Classify.vitals(body_param("vital_signs"))
      return render_failure(vitals) if vitals.failure?

      pain = Classify.pain_scale(body_param("pain_scale"), required: false)
      return render_failure(pain) if pain.failure?

      protocol = ActiveProtocol.current
      pain_scale = pain.payload[:pain_scale]
      suggested = pain_scale && Suggest.call(vitals: vitals.payload[:values], pain_scale: pain_scale,
                                             profile: Classify.profile(encounter.patient), protocol: protocol)
      levels = Levels.for(protocol).map { |color, minutes| { color: color, max_wait_minutes: minutes } }
      render json: { suggested: suggested, levels: levels }
    end
  end
end
