# Entrada no leito do acolhimento noturno (ADR 0049; plano, Desvio 1;
# contrato §5, P13, P25, P36).
#
# Corpo: `bed_id` (leito ativo de CAPS de NIGHT_MODALITIES), `enrollment_id`
# (matrícula aberta do MESMO CAPS, iniciada até a data local de `started_at`;
# senão enrollment_required em `enrollment_id`), `started_at` (no máximo 12 h no
# futuro), `expected_end_at` (depois da entrada, até 30 dias) e, só para passar
# do limite, `reassessment: { reason }` (10..500).
#
# Numa transação: trava a linha do CAPS (FOR SHARE, como RecordAction; o
# fechamento do mês trava FOR UPDATE) e a matrícula, e só então lê o
# fechamento do mês da primeira noite (month_closed em `started_at`). Leito
# ocupado → 409 bed_taken; paciente em outra permanência que ainda não acabou
# → 409 already_staying (o Ruby confere antes; a exclusion do leito e o índice
# único do paciente são a rede contra a corrida). Noites acima do limite → 422
# night_limit_reached `{ used, limit, window_days, rule }`, salvo
# `psychosocial_lead` com `reassessment`, que grava o motivo e quem reavaliou
# e publica `psychosocial.night_limit_overridden`. Abaixo do limite a
# reavaliação não é gravada. Publica `psychosocial.night_stay_started`. Os
# eventos levam só `night_stay_id`.
module Psychosocial
  module StartNightStay
    KEYS = %w[bed_id enrollment_id started_at expected_end_at reassessment].freeze
    KEY_PATH_MAX = 64
    FUTURE_TOLERANCE = 12.hours
    BED_EXCLUSION = "excl_psychosocial_night_stays_bed".freeze
    PATIENT_INDEX = "idx_psychosocial_night_stays_open_patient".freeze

    module_function

    # -> Result.ok(stay:) | fail(:invalid_request | :too_long | :caps_without_beds | :enrollment_required | :month_closed,
    #    details: { path:, problems: }) | fail(:bed_taken | :already_staying) |
    #    fail(:night_limit_reached, details: { used:, limit:, window_days:, rule: })
    def call(attrs:, by:, link:, now: Time.current)
      values, problems = check(attrs.to_h.stringify_keys, now)
      return refuse(problems) if problems.any?

      bed = values[:bed]
      return refuse([ problem("bed_id", "caps_without_beds") ]) unless bed.health_unit.night_capable?
      return refuse([ problem("bed_id") ]) unless link&.health_unit_id == bed.health_unit_id

      ApplicationRecord.transaction(requires_new: true) { start(values, by: by) }
    rescue ActiveRecord::StatementInvalid => e
      raise unless e.message.include?(BED_EXCLUSION) || e.message.include?(PATIENT_INDEX)

      Result.fail(e.message.include?(BED_EXCLUSION) ? :bed_taken : :already_staying)
    end

    def start(values, by:)
      bed = values[:bed]
      unit = HealthUnit.lock("FOR SHARE").find(bed.health_unit_id)
      started_at = values[:started_at]
      enrollment = PsychosocialEnrollment.lock("FOR SHARE").find_by(id: values[:enrollment_id])
      unless enrollment && enrollment.health_unit_id == unit.id && enrollment.open? &&
             enrollment.started_on <= started_at.in_time_zone.to_date
        return refuse([ problem("enrollment_id", "enrollment_required") ])
      end
      return refuse([ problem("started_at", "month_closed") ]) if MonthlyRecords.closed?(unit.id, started_at.in_time_zone.to_date)

      taken = conflict(bed.id, enrollment.patient_id, started_at)
      return Result.fail(taken) if taken

      over = NightLimit.check(patient_id: enrollment.patient_id, modality: unit.caps_modality,
                              new_nights: NightLimit.nights(started_at..values[:expected_end_at]), settings: Settings.current)
      return Result.fail(:night_limit_reached, details: over) if over && !(values[:reassessment] && Access.lead?(by))

      stay = PsychosocialNightStay.create!(
        psychosocial_bed: bed, health_unit: unit, psychosocial_enrollment: enrollment, patient_id: enrollment.patient_id,
        started_at: started_at, expected_end_at: values[:expected_end_at], started_by_user: by,
        reassessment_reason: (values[:reassessment] if over), reassessed_by_user: (by if over)
      )
      DomainEvents.publish("psychosocial.night_stay_started", night_stay_id: stay.id)
      DomainEvents.publish("psychosocial.night_limit_overridden", night_stay_id: stay.id) if over
      Result.ok(stay: stay)
    end

    # A conferência do Ruby antes da rede do banco: o leito com permanência que
    # ainda não acabou em `started_at` (a nova fica aberta: [started_at, ∞)) e o
    # paciente em outra permanência que ainda não acabou. -> :bed_taken | :already_staying | nil
    def conflict(bed_id, patient_id, started_at)
      running = PsychosocialNightStay.where("ended_at IS NULL OR ended_at > ?", started_at)
      return :bed_taken if running.exists?(psychosocial_bed_id: bed_id)

      :already_staying if running.exists?(patient_id: patient_id)
    end

    # -> [values, problems]
    def check(attrs, now)
      problems = (attrs.keys - KEYS).map { |key| problem(key[0, KEY_PATH_MAX]) }

      bed_id = attrs["bed_id"]
      bed = Input.uuid?(bed_id) ? PsychosocialBed.find_by(id: bed_id.downcase, active: true) : nil
      problems << problem("bed_id") unless bed
      enrollment_id = attrs["enrollment_id"]
      problems << problem("enrollment_id") unless Input.uuid?(enrollment_id)
      started_at = Input.time(attrs["started_at"])
      problems << problem("started_at") unless started_at && started_at <= now + FUTURE_TOLERANCE
      expected_end_at = Input.time(attrs["expected_end_at"])
      # Sem `started_at` válido, só a forma de `expected_end_at` é conferida.
      unless expected_end_at && (started_at.nil? || (expected_end_at > started_at &&
                                                     expected_end_at <= started_at + Catalog::MAX_EXPECTED_STAY_DAYS.days))
        problems << problem("expected_end_at")
      end
      reassessment = Reassessment.parse(attrs, problems)

      values = { bed: bed, enrollment_id: enrollment_id&.downcase, started_at: started_at, expected_end_at: expected_end_at,
                 reassessment: reassessment }
      [ values, problems.compact ]
    end

    def problem(path, error = "invalid_request") = { error: error, path: path }

    # Todas as recusas de uma vez; a primeira vai para o topo.
    def refuse(problems)
      first = problems.first
      Result.fail(first[:error].to_sym, details: { path: first[:path], problems: problems })
    end

    # `reassessment: { reason }` (P25: 10..500), na entrada e na saída.
    module Reassessment
      module_function

      # -> o motivo sem os espaços das pontas | nil (ausente ou recusado; a recusa vai a `problems`).
      def parse(attrs, problems)
        return nil unless attrs.key?("reassessment")

        value = attrs["reassessment"]
        unless value.is_a?(Hash) && value.keys.map(&:to_s) == %w[reason]
          problems << { error: "invalid_request", path: "reassessment" }
          return nil
        end
        refusal = Catalog.text_problem(value.values.first, Catalog::REASON, "reassessment.reason")
        return value.values.first.strip unless refusal

        problems << refusal
        nil
      end
    end

    private_class_method :start, :check
  end
end
