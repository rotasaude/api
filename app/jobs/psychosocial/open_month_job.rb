# Continuidade da RAAS (ADR 0049; contrato §6; plano, Desvio 6): todo dia, por
# cidade (EachCityJob), só com `psychosocial_care` utilizável (lido fora de
# qualquer transação da cidade), o registro `open` do mês corrente para toda
# matrícula aberta — a primeira execução do mês é a continuidade do dia 1º.
# Idempotente: o índice único (matrícula, mês) e ON CONFLICT DO NOTHING (a
# matrícula e a ação também abrem o registro). Por CAPS, numa transação que
# segura a linha da unidade (FOR SHARE, como MonthlyRecords.ensure!) para não
# correr com o fechamento; mês já fechado no CAPS não ganha registro. Log só
# com a contagem.
module Psychosocial
  class OpenMonthJob < ApplicationJob
    prepend EachCityJob
    queue_as :housekeeping

    def perform
      return unless Gate.usable?(Current.city)

      month = Time.zone.today.beginning_of_month
      opened = 0
      PsychosocialEnrollment.open_enrollments.where(started_on: ..month.end_of_month).distinct.pluck(:health_unit_id).each do |unit_id|
        opened += open_unit(unit_id, month)
      end
      Rails.logger.info("[#{self.class.name}] city=#{Current.city.slug} month=#{month.strftime('%Y-%m')} opened=#{opened}")
    end

    private

    # -> quantos registros nasceram no CAPS.
    def open_unit(unit_id, month)
      ApplicationRecord.transaction(requires_new: true) do
        HealthUnit.lock("FOR SHARE").find(unit_id)
        next 0 if MonthlyRecords.closed?(unit_id, month)

        rows = PsychosocialEnrollment.open_enrollments.where(health_unit_id: unit_id, started_on: ..month.end_of_month).pluck(:id).map do |id|
          { psychosocial_enrollment_id: id, health_unit_id: unit_id, month: month, status: "open" }
        end
        next 0 if rows.empty?

        PsychosocialMonthlyRecord.insert_all(rows, unique_by: %i[psychosocial_enrollment_id month]).rows.size
      end
    end
  end
end
