# Encerramento da matrícula (ADR 0049; contrato §4, P13; plano, Desvio 6):
# `destination` da lista do raas.yml, nunca "00" (permanência → 422
# destination_is_permanence); `closed_on` ISO, não futuro (422
# closed_on_in_future) e não antes do início. Já encerrada → 409
# already_closed. Grava destino e conclusão na RAAS do mês de `closed_on`
# (criada se faltar); com o mês fechado no CAPS → 422 month_closed (a
# coordenação reabre antes). Trava a linha do CAPS (FOR SHARE) e a matrícula.
# Publica `psychosocial.enrollment_closed` só com o id.
module Psychosocial
  module CloseEnrollment
    PERMANENCE = "00".freeze

    module_function

    # -> Result.ok(enrollment:) | fail(:already_closed) |
    #    fail(:invalid_request | :destination_is_permanence | :closed_on_in_future | :month_closed, details: { path:, problems: })
    def call(enrollment:, destination:, closed_on:, by:, today: Time.zone.today)
      return Result.fail(:already_closed) unless enrollment.open?

      date = Input.date(closed_on)
      problems = [ destination_problem(destination), date_problem(date, enrollment, today) ].compact
      return failure(problems) if problems.any?

      ApplicationRecord.transaction(requires_new: true) do
        HealthUnit.lock("FOR SHARE").find(enrollment.health_unit_id)
        enrollment.lock!
        next Result.fail(:already_closed) unless enrollment.open?

        # Mês fechado (ensure! não cria) ou registro já fora de `open`.
        record = MonthlyRecords.closed?(enrollment.health_unit_id, date) ? nil : MonthlyRecords.ensure!(enrollment, date, strict: true)
        next failure([ problem("closed_on", "month_closed") ]) unless record&.status == "open"

        enrollment.update!(closed_on: date, destination: destination, closed_by_user: by)
        record.update!(destination: destination, concluded_on: date)
        DomainEvents.publish("psychosocial.enrollment_closed", enrollment_id: enrollment.id)
        Result.ok(enrollment: enrollment)
      end
    end

    def destination_problem(destination)
      return problem("destination", "destination_is_permanence") if destination == PERMANENCE

      Raas.valid?(:destinations, destination) ? nil : problem("destination")
    end

    def date_problem(date, enrollment, today)
      return problem("closed_on") unless date
      return problem("closed_on", "closed_on_in_future") if date > today

      date < enrollment.started_on ? problem("closed_on") : nil
    end

    def problem(path, error = "invalid_request") = { error: error, path: path }

    def failure(problems)
      first = problems.first
      Result.fail(first[:error].to_sym, details: { path: first[:path], problems: problems })
    end

    private_class_method :destination_problem, :date_problem, :problem, :failure
  end
end
