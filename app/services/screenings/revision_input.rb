# app/services/screenings/revision_input.rb
# Corpo de uma revisão (ADR 0030; spec §3.1, §3.3; contratos §3) → colunas de
# screening_revisions. A cor sugerida é recalculada aqui com o protocolo
# ativo (nunca vem do cliente); a justificativa só fica quando a cor final
# difere de uma sugestão.
module Screenings
  module RevisionInput
    MAX_NOTE = 500
    MIN_REASON = 10

    module_function

    def call(params, citizen:)
      params = normalize(params)
      ciap = Ciap2.find(params["ciap2_code"])
      return Result.fail(:invalid_ciap2) unless ciap

      vitals = VitalSigns.parse(params["vitals"])
      return vitals if vitals.failure?

      note = params["complaint_note"].to_s.strip.presence
      return too_long("complaint_note") if note && note.length > MAX_NOTE

      final = params["final_color"].to_s
      return Result.fail(:invalid_color) unless RiskSuggestion::COLORS.include?(final)

      values = vitals.payload[:values]
      suggestion = Suggest.call(citizen: citizen, ciap2_code: ciap.code, vitals: values, bmi: vitals.payload[:bmi])
      reason = nil
      if suggestion[:color] && final != suggestion[:color]
        reason = params["color_change_reason"].to_s.strip
        return Result.fail(:color_change_reason_required) if reason.length < MIN_REASON
        return too_long("color_change_reason") if reason.length > MAX_NOTE
      end

      attrs = ScreeningRevision::VITAL_COLUMNS.to_h { |column| [ column, values[column] ] }.merge(
        "ciap2_code" => ciap.code, "ciap2_release_id" => ciap.release_id, "complaint_note" => note,
        "suggested_color" => suggestion[:color], "final_color" => final, "color_change_reason" => reason,
        "rule_protocol_definition_id" => suggestion[:protocol_definition_id], "matched_rules" => suggestion[:matched]
      )
      Result.ok(attrs: attrs, alerts: vitals.payload[:alerts], bmi: vitals.payload[:bmi])
    end

    def normalize(params)
      params = params.to_unsafe_h if params.respond_to?(:to_unsafe_h)
      params.is_a?(Hash) ? params.deep_stringify_keys : {}
    end

    def too_long(field) = Result.fail(:note_too_long, details: { field: field })
    private_class_method :normalize, :too_long
  end
end
