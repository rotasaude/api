# Desfecho do encontro da urgência (ADR 0050; contrato §7 e §14 Q10, Q15,
# Q25; plano, Desvio 13): grava o desfecho (um por encontro, imutável), fecha
# o encontro e o atendimento do 13 pelo Attendances::Close com o `outcome`
# equivalente (Urgency::Catalog::OUTCOME_MAP).
#
# Quem: o médico (vínculo 225* na UPA) registra qualquer desfecho; a recepção
# (citizen_verifier) e a enfermagem (2235*) só os de balcão (DESK_OUTCOMES:
# left_without_care e registered_in_error); os demais → Access.refusal
# (missing_role | missing_link | cbo_not_allowed).
#
# Corpo: `{ kind, destination?, vacancy_request?, return_guidance?: { days,
# reason }, reason? }`, as recusas de forma todas de uma vez em `problems`:
# chave desconhecida ou campo de outro desfecho → invalid_request com o path;
# `transferred` sem destino → destination_required (fora de DESTINATION →
# invalid_request `destination`); `discharged_to_primary_care` sem a
# orientação → return_guidance_required (dias fora de RETURN_DAYS ou motivo
# fora de RETURN_REASON → invalid_request `return_guidance.days`/`.reason`);
# `registered_in_error` sem motivo em ERROR_REASON → invalid_request `reason`.
#
# Estado (sob attendance.lock! → encounter.lock!): encontro ou atendimento
# fechado → encounter_closed; IDENTIFIED_OUTCOMES de provisório →
# patient_unidentified; os de balcão valem em qualquer estado, mas consulta em
# rascunho → consultation_in_progress (a do Close); left_against_advice com
# rascunho também; os demais exigem a consulta de urgência finalizada →
# consultation_not_finalized.
#
# `team`: a equipe da contrarreferência (CareLines::TeamPopulation), lida
# FORA da transação pelo chamador — só na alta para a UBS; a unidade é a da
# equipe. Evento urgency.encounter_closed, só com o encounter_id. Destino,
# pedido de vaga e motivos nunca em evento, log nem recusa.
module Urgency
  module RecordOutcome
    KEYS = %w[kind destination vacancy_request return_guidance reason].freeze
    GUIDANCE_KEYS = %w[days reason].freeze
    # Campo → o único desfecho que o aceita.
    FIELD_KIND = { "destination" => "transferred", "vacancy_request" => "transferred",
                   "return_guidance" => "discharged_to_primary_care", "reason" => Catalog::REGISTERED_IN_ERROR }.freeze
    LEFT_KINDS = (Catalog::DESK_OUTCOMES + %w[left_against_advice]).freeze
    KEY_PATH_MAX = 64
    EVENT = "urgency.encounter_closed".freeze

    module_function

    # -> Result.ok(outcome:, attendance:) | Result.fail(reason, details: { path:, problems: }?)
    def call(encounter:, attrs:, by:, team: nil, now: Time.current)
      kind = attrs.is_a?(Hash) ? attrs.stringify_keys["kind"] : nil
      access = authorize(by, encounter.attendance.health_unit_id, kind)
      return Result.fail(access) unless access == :ok

      input = parse(attrs)
      return input if input.failure?

      persist(encounter, input.payload, by, team, now)
    end

    # `kind` fora de OUTCOMES: confere só o acesso de balcão (a recusa de
    # forma vem depois, no parse).
    def authorize(by, unit_id, kind)
      return :ok if Access.physician_link(by, unit_id)

      desk = Catalog::DESK_OUTCOMES.include?(kind) || !Catalog::OUTCOMES.include?(kind)
      return :ok if desk && (Access.reception?(by) || Access.clinical_link(by, unit_id))

      Access.refusal(by, unit_id)
    end

    def parse(attrs)
      return refuse(:invalid_request, "body") unless attrs.is_a?(Hash)

      attrs = attrs.stringify_keys
      kind = attrs["kind"]
      problems = (attrs.keys - KEYS).map { |key| problem(key.to_s[0, KEY_PATH_MAX]) }
      unless Catalog::OUTCOMES.include?(kind)
        problems << problem("kind")
        return failure(problems)
      end

      FIELD_KIND.each { |field, owner| problems << problem(field) if attrs.key?(field) && owner != kind }
      values = { kind: kind }
      case kind
      when "transferred"
        values[:destination] = destination(attrs, problems)
        values[:vacancy_request] = vacancy_request(attrs, problems)
      when "discharged_to_primary_care"
        values[:return_days], values[:return_reason] = return_guidance(attrs, problems)
      when Catalog::REGISTERED_IN_ERROR
        reason = text(attrs["reason"])
        problems << problem("reason") unless reason && Catalog::ERROR_REASON.cover?(reason.length)
        values[:error_reason] = reason
      end
      problems.any? ? failure(problems) : Result.ok(values)
    end

    def destination(attrs, problems)
      if attrs["destination"].nil?
        problems << problem("destination", :destination_required)
        return nil
      end

      value = text(attrs["destination"])
      problems << problem("destination") unless value && Catalog::DESTINATION.cover?(value.length)
      value
    end

    def vacancy_request(attrs, problems)
      return nil if attrs["vacancy_request"].nil?

      value = attrs["vacancy_request"].is_a?(String) ? attrs["vacancy_request"].strip : nil
      problems << problem("vacancy_request") unless value && value.length <= Catalog::VACANCY_REQUEST_MAX
      value.presence
    end

    def return_guidance(attrs, problems)
      raw = attrs["return_guidance"]
      problems << problem("return_guidance", :return_guidance_required) if raw.nil?
      problems << problem("return_guidance") unless raw.nil? || raw.is_a?(Hash)
      return [ nil, nil ] unless raw.is_a?(Hash)

      raw = raw.stringify_keys
      (raw.keys - GUIDANCE_KEYS).each { |key| problems << problem("return_guidance.#{key.to_s[0, KEY_PATH_MAX]}") }
      days = raw["days"]
      problems << problem("return_guidance.days") unless days.is_a?(Integer) && Catalog::RETURN_DAYS.cover?(days)
      reason = text(raw["reason"])
      problems << problem("return_guidance.reason") unless reason && Catalog::RETURN_REASON.cover?(reason.length)
      [ days, reason ]
    end

    def persist(encounter, values, by, team, now)
      result = nil
      ApplicationRecord.transaction(requires_new: true) do
        attendance = encounter.attendance
        attendance.lock!
        encounter.lock!
        result = state_refusal(encounter, attendance, values[:kind])
        next if result

        kind = values[:kind]
        counter = kind == "discharged_to_primary_care" ? team : nil
        outcome = UrgencyOutcome.create!(
          urgency_encounter: encounter, kind: kind, destination: values[:destination], vacancy_request: values[:vacancy_request],
          return_days: values[:return_days], return_reason: values[:return_reason], error_reason: values[:error_reason],
          counter_referral_health_team: counter, counter_referral_health_unit_id: counter&.health_unit_id,
          recorded_by_user: by, recorded_at: now, created_at: now
        )
        encounter.update!(state: "closed")
        closed = Attendances::Close.call(attendance: attendance, outcome: nil, referral_unit_id: nil, referral_note: nil, by: by,
                                         urgency_outcome: outcome, urgency: true)
        if closed.failure?
          result = closed
          raise ActiveRecord::Rollback
        end

        DomainEvents.publish(EVENT, encounter_id: encounter.id)
        result = Result.ok(outcome: outcome, attendance: closed.payload[:attendance])
      end
      result
    end

    # -> Result.fail | nil
    def state_refusal(encounter, attendance, kind)
      return Result.fail(:encounter_closed) if encounter.closed? || encounter.outcome || attendance.status == "closed"

      patient = Patient.find(attendance.patient_id)
      return Result.fail(:invalid_request, details: { path: "patient" }) if patient.merged?
      return Result.fail(:patient_unidentified) if Catalog::IDENTIFIED_OUTCOMES.include?(kind) && patient.unidentified

      statuses = Consultation.where(attendance_id: attendance.id).pluck(:status)
      return Result.fail(:consultation_in_progress) if LEFT_KINDS.include?(kind) && statuses.include?("draft")
      return nil if Catalog::DESK_OUTCOMES.include?(kind)

      statuses.include?("finalized") ? nil : Result.fail(:consultation_not_finalized)
    end

    def text(value) = value.is_a?(String) ? value.strip.presence : nil
    def problem(path, error = :invalid_request) = { path: path, error: error }
    def failure(problems) = Result.fail(problems.first[:error], details: { path: problems.first[:path], problems: problems })
    def refuse(reason, path) = Result.fail(reason, details: { path: path })
    private_class_method :authorize, :parse, :destination, :vacancy_request, :return_guidance, :persist, :state_refusal,
                         :text, :problem, :failure, :refuse
  end
end
