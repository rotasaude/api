# Classificação de risco e reclassificação na UPA (ADR 0050; contrato §5 e
# §14 Q1, Q2, Q3, Q18, Q22; plano, Desvios 8–10).
#
# Quem: health_professional com vínculo ativo 2235* na UPA do encontro
# (Urgency::Access.classifier: missing_role | missing_link | cbo_not_allowed).
# Encontro (ou atendimento) fechado → encounter_closed.
#
# Corpo: `{ complaint, vital_signs, pain_scale, color, justification? }`, as
# recusas de forma todas de uma vez em `problems` (chave desconhecida, queixa
# fora de COMPLAINT, sinais pelo Screenings::VitalSigns do 18 sem `pain_score`
# — path `vital_signs.<campo>` —, `pain_scale` ausente → pain_scale_required,
# fora de PAIN → invalid_request, cor fora de COLORS). Depois, a sugestão do
# protocolo ativo sobre os sinais, a dor e o perfil (idade e sexo; provisório
# sem perfil): cor diferente da sugerida, ou sem sugestão, e justificativa fora
# de JUSTIFICATION → justification_required; justificativa dada fora de
# JUSTIFICATION onde não é exigida → invalid_request `path: "justification"`
# (a classificação é só acréscimo: o texto nunca é descartado em silêncio).
#
# Na transação (attendance.lock! → encounter.lock!): a classificação seguinte
# (`position`), com a foto do tempo máximo da cor (`Levels.for` do protocolo
# ativo, ou o padrão) e o protocolo da sugestão, o CBO do vínculo e o critério
# da regra sugerida (cifrado); o encontro aponta a vigente, `first_classified_at`
# na 1ª e `waiting_classification → classified` (depois, o estado não muda).
# Evento urgency.classified (1ª) ou urgency.reclassified, só com ids. A queixa,
# os sinais e a justificativa nunca vão para evento, log nem recusa.
module Urgency
  module Classify
    KEYS = %w[complaint vital_signs pain_scale color justification].freeze
    VITAL_FIELDS = (Screenings::VitalSigns::FIELDS - %w[pain_score]).freeze
    KEY_PATH_MAX = 64

    module_function

    # -> Result.ok(classification:, suggested: { color, criterion, rule_id } | nil) | Result.fail(reason, details: { path:, problems: }?)
    def call(encounter:, attrs:, by:, now: Time.current)
      access = Access.classifier(by, encounter.attendance.health_unit_id)
      return access if access.failure?
      return Result.fail(:encounter_closed) if closed?(encounter)

      input = parse(attrs)
      return input if input.failure?

      values = input.payload
      protocol = ActiveProtocol.current
      suggested = Suggest.call(vitals: values[:vitals], pain_scale: values[:pain_scale], profile: profile(encounter.patient),
                               protocol: protocol)
      justification = values[:justification]
      valid = justification.nil? || Catalog::JUSTIFICATION.cover?(justification.length)
      if suggested.nil? || suggested[:color] != values[:color]
        return refuse(:justification_required, "justification") unless justification && valid
      elsif !valid
        return Result.fail(:invalid_request, details: { path: "justification", problems: [ problem("justification") ] })
      end

      persist(encounter, values, suggested, protocol, access.payload.fetch(:link), by, now)
    end

    # Sinais do 18 sem a dor (que é `pain_scale`, Q3): chave fora dos campos →
    # invalid_request `vital_signs.<chave>`; implausível → o campo; pressão
    # incompleta → o lado que falta. -> Result.ok(values:) | Result.fail(:invalid_request, path:)
    def vitals(raw)
      raw = {} if raw.nil?
      return refuse(:invalid_request, "vital_signs") unless raw.is_a?(Hash)

      raw = raw.transform_keys(&:to_s)
      unknown = (raw.keys - VITAL_FIELDS).first
      return refuse(:invalid_request, "vital_signs.#{unknown[0, KEY_PATH_MAX]}") if unknown

      parsed = Screenings::VitalSigns.parse(raw)
      return Result.ok(values: parsed.payload[:values]) if parsed.ok?

      field = parsed.details[:field]
      field ||= raw["systolic"].to_s.strip.present? ? "diastolic" : "systolic"
      refuse(:invalid_request, "vital_signs.#{field}")
    end

    # Dor 0..10, inteiro. Nula ou ausente → pain_scale_required (na prévia,
    # `required: false`, vale nil). -> Result.ok(pain_scale:) | Result.fail
    def pain_scale(raw, required: true)
      return(required ? refuse(:pain_scale_required, "pain_scale") : Result.ok(pain_scale: nil)) if raw.nil?
      return refuse(:invalid_request, "pain_scale") unless raw.is_a?(Integer) && Catalog::PAIN.cover?(raw)

      Result.ok(pain_scale: raw)
    end

    # Perfil da condição: idade e sexo do paciente; o provisório não tem.
    def profile(patient)
      return {} if patient.unidentified

      { age: patient.age, sex: patient.sex }.compact
    end

    def closed?(encounter) = encounter.closed? || encounter.attendance.status == "closed"

    def parse(attrs)
      return refuse(:invalid_request, "body") unless attrs.is_a?(Hash)

      attrs = attrs.stringify_keys
      problems = (attrs.keys - KEYS).map { |key| problem(key.to_s[0, KEY_PATH_MAX]) }
      complaint = text(attrs["complaint"])
      problems << problem("complaint") unless complaint && Catalog::COMPLAINT.cover?(complaint.length)
      vitals = vitals(attrs["vital_signs"])
      problems << failure_problem(vitals) if vitals.failure?
      pain = pain_scale(attrs["pain_scale"])
      problems << failure_problem(pain) if pain.failure?
      color = attrs["color"]
      problems << problem("color") unless Catalog::COLORS.include?(color)
      justification = text(attrs["justification"])
      problems << problem("justification") unless attrs["justification"].nil? || attrs["justification"].is_a?(String)
      return Result.fail(problems.first[:error], details: { path: problems.first[:path], problems: problems }) if problems.any?

      Result.ok(complaint: complaint, vitals: vitals.payload[:values], pain_scale: pain.payload[:pain_scale], color: color,
                justification: justification)
    end

    def persist(encounter, values, suggested, protocol, link, by, now)
      ApplicationRecord.transaction do
        encounter.attendance.lock!
        encounter.lock!
        next Result.fail(:encounter_closed) if closed?(encounter)

        first = encounter.current_classification_id.nil?
        classification = UrgencyClassification.create!(
          urgency_encounter: encounter, position: (encounter.classifications.maximum(:position) || 0) + 1,
          color: values[:color], suggested_color: suggested&.dig(:color), suggested_rule_id: suggested&.dig(:rule_id),
          criterion: suggested&.dig(:criterion), complaint: values[:complaint],
          vital_signs: Screenings::VitalSigns.json(values[:vitals]), pain_scale: values[:pain_scale],
          justification: values[:justification], max_wait_minutes: Levels.for(protocol).fetch(values[:color]),
          protocol_definition: protocol, classified_by_user: by, professional_link: link, cbo_code: link.cbo_code,
          created_at: now
        )
        encounter.update!(current_classification: classification, first_classified_at: encounter.first_classified_at || now,
                          state: encounter.state == "waiting_classification" ? "classified" : encounter.state)
        DomainEvents.publish(first ? "urgency.classified" : "urgency.reclassified",
                             encounter_id: encounter.id, classification_id: classification.id)
        Result.ok(classification: classification, suggested: suggested)
      end
    end

    def text(value) = value.is_a?(String) ? value.strip.presence : nil
    def problem(path, error = :invalid_request) = { path: path, error: error }
    def failure_problem(result) = problem(result.details.fetch(:path), result.reason)
    def refuse(reason, path) = Result.fail(reason, details: { path: path })
    private_class_method :closed?, :parse, :persist, :text, :problem, :failure_problem, :refuse
  end
end
