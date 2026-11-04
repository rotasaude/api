# Acolhimento no CAPS (ADR 0049; contrato §4, P7, P12), com ou sem
# encaminhamento. O CAPS vem da lotação de quem pede. Campos: `patient_id`;
# `referral_id` opcional (encaminhamento deste CAPS e deste paciente; travado
# FOR UPDATE e conferido `pending`, senão 409 referral_not_pending; usado, vira
# `received`); `at` (data e hora, não futura); `sigtap_code` com instrumento
# RAAS-PSI (09) ou BPA-I (02) na SIGTAP da competência de `at` (senão
# instrument_mismatch); `notes` opcional (até 4000, cifrado; acima →
# too_long); `outcome` (enrolled | referred_elsewhere | no_follow_up).
# `enrolled` exige o bloco `enrollment` (os campos da CreateEnrollment sem CAPS
# nem paciente; os problemas dele vêm com o prefixo `enrollment.`) e cria a
# matrícula na mesma transação: falha na matrícula desfaz a recepção. Outro
# desfecho com o bloco → invalid_request `enrollment`. Recusas de campo todas
# de uma vez. Publica `psychosocial.reception_recorded` só com o id.
# O acolhimento é também uma ação (Task 7): Psychosocial::RecordAction na mesma
# transação, `origin: "reception"`, em `at`, no CAPS, quantidade 1, sem notas
# (as da recepção ficam nela), com o participante = a matrícula criada ou o
# paciente; o instrumento sai do Desvio 3 (código só 09 sem matrícula →
# enrollment_required). A crítica da ação recusa tudo com 422
# action_rejected, nos campos da recepção: `performed_at` → `at`; a matrícula
# criada que não vale na data do acolhimento (`at` antes do `started_on`,
# enrollment_required do participante) → `at`; os demais → `sigtap_code` (o
# acolhimento não tem quantidade, autorização nem lista de participantes).
module Psychosocial
  module RecordReception
    KEYS = %w[health_unit_id patient_id referral_id at sigtap_code notes outcome enrollment].freeze
    RECEPTION_INSTRUMENTS = %w[09 02].freeze
    SIGTAP_CODE = /\A\d{10}\z/
    ENROLLED = "enrolled".freeze
    KEY_PATH_MAX = 64

    module_function

    # link: o vínculo de quem acolhe no CAPS (o CBO da ação).
    # -> Result.ok(reception:, enrollment:) | fail(:referral_not_pending | :enrollment_open) |
    #    fail(:action_rejected, details: { problems: }) |
    #    fail(:invalid_request | :too_long | :instrument_mismatch | ..., details: { path:, problems: })
    def call(attrs:, unit:, by:, link: Access.link(by, unit.id), now: Time.current)
      attrs = attrs.to_h.stringify_keys
      problems = (attrs.keys - KEYS).map { |key| problem(key[0, KEY_PATH_MAX]) }

      patient = Input.uuid?(attrs["patient_id"]) ? Patient.find_by(id: attrs["patient_id"]) : nil
      problems << problem("patient_id") unless patient
      at = Input.time(attrs["at"])
      problems << problem("at") unless at && at <= now
      notes = attrs["notes"]
      problems.concat([ code_problem(attrs["sigtap_code"], at), notes.nil? ? nil : Catalog.text_problem(notes, Catalog::NOTES, "notes") ].compact)
      outcome = attrs["outcome"]
      problems << problem("outcome") unless Catalog::RECEPTION_OUTCOMES.include?(outcome)
      referral = referral(attrs, unit, patient, problems)
      values = enrollment_values(attrs, outcome, unit, problems)
      return failure(problems) if problems.any?

      result = nil
      ApplicationRecord.transaction(requires_new: true) do
        result = record(attrs, unit: unit, patient: patient, at: at, notes: notes&.strip, referral: referral, values: values, by: by,
                               link: link, now: now)
        raise ActiveRecord::Rollback if result.failure?
      end
      result
    end

    def record(attrs, unit:, patient:, at:, notes:, referral:, values:, by:, link:, now:)
      if referral
        referral.lock!
        return Result.fail(:referral_not_pending) unless referral.status == "pending"
      end

      reception = PsychosocialReception.create!(health_unit: unit, patient: patient, psychosocial_referral: referral, at: at,
                                                sigtap_code: attrs["sigtap_code"], notes: notes, outcome: attrs["outcome"],
                                                recorded_by_user: by)
      referral&.update!(status: "received", received_at: now)
      enrollment = nil
      if values
        enrolled = CreateEnrollment.insert(values, patient: patient, unit: unit, by: by, reception: reception)
        return prefixed(enrolled) if enrolled.failure?

        enrollment = enrolled.payload.fetch(:enrollment)
      end
      participant = enrollment ? { "enrollment_id" => enrollment.id } : { "patient_id" => patient.id }
      action = RecordAction.call(attrs: { "sigtap_code" => attrs["sigtap_code"], "performed_at" => at.iso8601, "place" => "caps",
                                          "quantity" => 1, "participants" => [ participant ] },
                                 unit: unit, by: by, link: link, origin: "reception", now: now)
      return action_refusal(action) if action.failure?

      DomainEvents.publish("psychosocial.reception_recorded", reception_id: reception.id)
      Result.ok(reception: reception, enrollment: enrollment)
    end

    # A recusa da matrícula com os paths do bloco (`enrollment.started_on`).
    def prefixed(result)
      return result unless result.details.key?(:problems)

      problems = result.details[:problems].map { |p| p.merge(path: "enrollment.#{p[:path]}") }
      Result.fail(result.reason, details: result.details.merge(path: problems.first[:path], problems: problems))
    end

    # A crítica da ação nos campos da recepção (sem participant_index).
    def action_refusal(result)
      return result unless result.reason == :action_rejected

      problems = result.details[:problems].map do |p|
        { error: p[:error], path: p[:path] == "performed_at" || p.key?(:participant_index) ? "at" : "sigtap_code" }
      end
      Result.fail(:action_rejected, details: { problems: problems.uniq })
    end

    # nil (aceito) | o problema. Sem `at` válido, só a forma do código.
    def code_problem(code, at)
      return problem("sigtap_code") unless code.is_a?(String) && code.match?(SIGTAP_CODE)
      return nil unless at

      release = Terminology::Sigtap.release_for(at.in_time_zone.strftime("%Y%m"))
      instruments = release ? SigtapProcedureInstrument.where(release_id: release.id, procedure_code: code).pluck(:instrument_code) : []
      instruments.intersect?(RECEPTION_INSTRUMENTS) ? nil : problem("sigtap_code", "instrument_mismatch")
    end

    # O encaminhamento deste CAPS e deste paciente (sem travar: a trava é na transação).
    def referral(attrs, unit, patient, problems)
      id = attrs["referral_id"]
      return nil if id.nil?

      referral = Input.uuid?(id) ? PsychosocialReferral.find_by(id: id, health_unit_id: unit.id) : nil
      return referral if referral && patient && referral.patient_id == patient.id

      problems << problem("referral_id") if referral.nil? || patient
      nil
    end

    # Os valores da matrícula, só com `enrolled` (nil sem matrícula).
    def enrollment_values(attrs, outcome, unit, problems)
      block = attrs["enrollment"]
      unless outcome == ENROLLED
        problems << problem("enrollment") unless block.nil?
        return nil
      end
      unless block.is_a?(Hash)
        problems << problem("enrollment")
        return nil
      end

      values, block_problems = CreateEnrollment.check(block.stringify_keys, unit: unit)
      problems.concat(block_problems.map { |p| p.merge(path: "enrollment.#{p[:path]}") })
      values
    end

    def problem(path, error = "invalid_request") = { error: error, path: path }

    def failure(problems)
      first = problems.first
      Result.fail(first[:error].to_sym, details: { path: first[:path], problems: problems })
    end

    private_class_method :record, :prefixed, :action_refusal, :code_problem, :referral, :enrollment_values, :problem, :failure
  end
end
