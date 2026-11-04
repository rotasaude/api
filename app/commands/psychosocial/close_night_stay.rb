# Saída do leito do acolhimento noturno (ADR 0049; plano, Desvio 1; contrato
# §5, P12, P13, P25, P36; preflight, Tabela C 7 → 8).
#
# `ended_at` depois da entrada e não futuro; `reason` (10..500). As noites
# reais são as de `started_at ... ended_at` (Desvio 1). Se passarem do limite
# e a permanência ainda não foi reavaliada, vale a regra da entrada: 422
# night_limit_reached, salvo `psychosocial_lead` com `reassessment: { reason }`,
# gravada junto do fechamento (o trigger aceita a reavaliação uma vez, só com
# o fechamento) e publicada em `psychosocial.night_limit_overridden`.
#
# Numa transação: trava a linha do CAPS (FOR SHARE, como RecordAction) e a
# permanência, e só então lê o fechamento dos meses: noite em mês fechado →
# 422 month_closed (em `ended_at`) e nada fecha. Fecha a permanência e grava,
# pela via de RecordAction, uma ação RAAS por noite (`origin: "night_stay"`,
# `night_sigtap_code` do raas.yml, quantidade 1, às 20:00 locais da noite
# dentro da permanência, profissional = quem fecha). Qualquer
# recusa da crítica desfaz tudo e volta como 422 action_rejected. Publica
# `psychosocial.night_stay_closed` só com o id.
module Psychosocial
  module CloseNightStay
    NIGHT_HOUR = 20

    module_function

    # -> Result.ok(stay:) | fail(:already_closed) | fail(:action_rejected, details: { problems: }) |
    #    fail(:invalid_request | :too_long | :month_closed, details: { path:, problems: }) |
    #    fail(:night_limit_reached, details: { used:, limit:, window_days:, rule: })
    def call(stay:, ended_at:, reason:, by:, link:, reassessment: nil, now: Time.current)
      return Result.fail(:already_closed) unless stay.open?

      problems = []
      ended = Input.time(ended_at)
      problems << { error: "invalid_request", path: "ended_at" } unless ended && ended > stay.started_at && ended <= now
      refusal = Catalog.text_problem(reason, Catalog::REASON, "reason")
      problems << refusal if refusal
      reassessment = StartNightStay::Reassessment.parse(reassessment.nil? ? {} : { "reassessment" => reassessment }, problems)
      return refuse(problems) if problems.any?

      outcome = nil
      ApplicationRecord.transaction(requires_new: true) do
        outcome = close(stay, ended: ended, reason: reason.strip, by: by, link: link, reassessment: reassessment, now: now)
        raise ActiveRecord::Rollback if outcome.failure?
      end
      outcome
    end

    def close(stay, ended:, reason:, by:, link:, reassessment:, now:)
      unit = HealthUnit.lock("FOR SHARE").find(stay.health_unit_id)
      stay.lock!
      return Result.fail(:already_closed) unless stay.open?

      nights = NightLimit.nights(stay.started_at..ended)
      return refuse([ { error: "month_closed", path: "ended_at" } ]) if nights.map(&:beginning_of_month).uniq.any? { |month| MonthlyRecords.closed?(unit.id, month) }

      override = false
      if stay.reassessment_reason.nil?
        over = NightLimit.check(patient_id: stay.patient_id, modality: unit.caps_modality, new_nights: nights,
                                settings: Settings.current, except_stay_id: stay.id)
        return Result.fail(:night_limit_reached, details: over) if over && !(reassessment && Access.lead?(by))

        override = over.present?
      end

      stay.update!(ended_at: ended, end_reason: reason, closed_by_user: by,
                   **(override ? { reassessment_reason: reassessment, reassessed_by_user: by } : {}))
      nights.each do |night|
        result = RecordAction.call(attrs: night_action(stay, night, ended), unit: unit, by: by, link: link,
                                   origin: "night_stay", night_stay: stay, now: now)
        return result if result.failure?
      end

      DomainEvents.publish("psychosocial.night_stay_closed", night_stay_id: stay.id)
      DomainEvents.publish("psychosocial.night_limit_overridden", night_stay_id: stay.id) if override
      Result.ok(stay: stay)
    end

    # A ação da noite, no CAPS: 20:00 locais da data, dentro da permanência
    # (a entrada, se foi depois; a saída, se foi antes) — sempre na data da noite.
    def night_action(stay, night, ended)
      performed_at = [ [ night.in_time_zone.change(hour: NIGHT_HOUR), stay.started_at ].max, ended ].min
      { "sigtap_code" => Raas.config.fetch("night_sigtap_code"), "performed_at" => performed_at.iso8601, "place" => "caps",
        "quantity" => 1, "participants" => [ { "enrollment_id" => stay.psychosocial_enrollment_id } ] }
    end

    def refuse(problems)
      first = problems.first
      Result.fail(first[:error].to_sym, details: { path: first[:path], problems: problems })
    end

    private_class_method :close, :night_action, :refuse
  end
end
