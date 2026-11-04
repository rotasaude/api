# Encaminhamento da UBS ao CAPS (ADR 0049; contrato §4, P12, P25). Escreve o
# health_professional com vínculo ativo numa unidade que não é CAPS (o mais
# antigo dá `from_health_unit_id`; sem ele → missing_role), com leitura
# permitida do prontuário do paciente (ClinicalRecord::Access: em contexto ou
# abertura justificada; senão → out_of_context). Campos: `patient_id`,
# `health_unit_id` (CAPS ativo), `reason` (10..2000, cifrado; acima →
# too_long), `priority` (routine | priority); recusas de campo todas de uma
# vez. Nasce `pending` e publica `psychosocial.referral_created` só com o id.
module Psychosocial
  module CreateReferral
    KEYS = %w[patient_id health_unit_id reason priority].freeze
    KEY_PATH_MAX = 64

    module_function

    # -> Result.ok(referral:) | fail(:missing_role | :out_of_context) |
    #    fail(:invalid_request | :too_long, details: { path:, problems: })
    def call(attrs:, by:, now: Time.current)
      link = Access.referrer_link(by)
      return Result.fail(:missing_role) unless link

      attrs = attrs.to_h.stringify_keys
      patient = Input.uuid?(attrs["patient_id"]) ? Patient.find_by(id: attrs["patient_id"]) : nil
      return Result.fail(:out_of_context) if patient && !ClinicalRecord::Access.call(user: by, patient: patient, now: now).allowed?

      problems = (attrs.keys - KEYS).map { |key| problem(key[0, KEY_PATH_MAX]) }
      problems << problem("patient_id") unless patient
      unit = Input.uuid?(attrs["health_unit_id"]) ? HealthUnit.find_by(id: attrs["health_unit_id"], kind: "caps", active: true) : nil
      problems << problem("health_unit_id") unless unit
      text = Catalog.text_problem(attrs["reason"], Catalog::REFERRAL_REASON, "reason")
      problems << text if text
      problems << problem("priority") unless Catalog::REFERRAL_PRIORITIES.include?(attrs["priority"])
      return failure(problems) if problems.any?

      PsychosocialReferral.transaction(requires_new: true) do
        referral = PsychosocialReferral.create!(patient: patient, health_unit: unit, from_health_unit_id: link.health_unit_id,
                                                referred_by_user: by, reason: attrs["reason"].strip, priority: attrs["priority"],
                                                status: "pending")
        DomainEvents.publish("psychosocial.referral_created", referral_id: referral.id)
        Result.ok(referral: referral)
      end
    end

    def problem(path, error = "invalid_request") = { error: error, path: path }

    def failure(problems)
      first = problems.first
      Result.fail(first[:error].to_sym, details: { path: first[:path], problems: problems })
    end

    private_class_method :problem, :failure
  end
end
