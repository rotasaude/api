# Negativa semanal da unidade (módulo 25, ADR 0043; contrato K7): "nenhum caso
# nesta semana epidemiológica". Recusas, na ordem:
#
#   invalid_week            texto fora de AAAA-SS (EpiWeek.parse nil; não-texto);
#   future_week             o sábado da semana depois de hoje no fuso da cidade
#                           (a semana corrente conta como futura);
#   invalid_unit            inexistente, inativa ou não notificadora;
#   unit_has_notifications  caso da unidade na semana (Surveillance::WeekCases,
#                           a mesma regra do lembrete): 409;
#   already_recorded        negativa da unidade na semana: 409, conferida sob o
#                           lock da unidade e, por garantia, pelo índice único
#                           (RecordNotUnique no SAVEPOINT) — nunca 500 nem a
#                           mensagem do Postgres.
#
# Sem dado de pessoa: só ids e a semana.
module Surveillance
  module RecordNegative
    INDEX = "idx_weekly_negative_reports_unit_week".freeze

    module_function

    # -> Result.ok(week:, unit:, report:) | fail(:invalid_week | :future_week | :invalid_unit |
    # :unit_has_notifications | :already_recorded).
    def call(unit_id:, week:, by:, today: Time.zone.today)
      raise ArgumentError, "by required" if by.nil?

      parsed = EpiWeek.parse(week)
      return Result.fail(:invalid_week) if parsed.nil?
      return Result.fail(:future_week) if parsed.ends_on > today

      ApplicationRecord.transaction(requires_new: true) do
        # A trava da unidade serializa as negativas concorrentes dela.
        unit = HealthUnit.lock.find_by(id: unit_id)
        next Result.fail(:invalid_unit) unless unit && unit.active && unit.notifying
        next Result.fail(:unit_has_notifications) if WeekCases.unit_ids_with_cases(parsed).include?(unit.id)
        next Result.fail(:already_recorded) if WeeklyNegativeReport.exists?(health_unit_id: unit.id, week: parsed.to_s)

        report = WeeklyNegativeReport.create!(health_unit: unit, week: parsed.to_s, recorded_by_user: by)
        DomainEvents.publish("weekly_negative.recorded", weekly_negative_report_id: report.id, user_id: by.id)
        Result.ok(week: parsed, unit: unit, report: report)
      end
    rescue ActiveRecord::RecordNotUnique => e
      raise unless e.message.include?(INDEX)

      Result.fail(:already_recorded)
    end
  end
end
