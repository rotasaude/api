# Varredor diário (ADR 0030; spec §5): às 23h no fuso da cidade, gera a ficha
# das escutas concluídas cujos atendimentos ainda estão abertos (a pessoa
# esperou o dia todo, ou ninguém encerrou). Também alcança atendimentos já
# fechados cuja escuta ficou sem ficha e sem "não gerada" (a exportação estava
# inutilizável no fechamento): decisão do usuário 2026-10-07 (diverge da spec
# §5), limitada à competência LEDI atual e à anterior (completed_at desde o
# início do mês passado). Se a exportação ainda não serve, nada acontece e
# tenta-se na noite seguinte. Escuta com "não gerada" (resolvida ou não) é do
# caminho de falha / "gerar de novo". Agendado a cada hora; só age na hora 23
# local (CityConnection.with usa o fuso da cidade).
module Ledi
  class ScreeningFichaSweepJob < ApplicationJob
    prepend EachCityJob
    queue_as :housekeeping

    SWEEP_HOUR = 23

    def perform
      return unless Time.current.hour == SWEEP_HOUR

      source = Ledi::ScreeningFicha::SOURCE_TYPE
      since = Time.current.beginning_of_month.prev_month
      failed = LediGenerationFailure.where(source_type: source).select(:source_id)
      late_closed = Attendance.where(status: "closed").where(screenings: { completed_at: since.. }).where.not(screenings: { id: failed })
      Screening.completed_screenings.joins(:attendance)
               .where.not(id: LediOutboxEntry.where(source_type: source).select(:source_id))
               .merge(Attendance.open_attendances.or(late_closed))
               .find_each { |screening| Ledi::ScreeningFicha.generate(screening, city: Current.city) }
    end
  end
end
