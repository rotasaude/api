# Varredor diário (ADR 0030; spec §5): às 23h no fuso da cidade, gera a ficha
# das escutas concluídas cujos atendimentos ainda estão abertos (a pessoa
# esperou o dia todo, ou ninguém encerrou). Agendado a cada hora; só age na
# hora 23 local (CityConnection.with usa o fuso da cidade).
module Ledi
  class ScreeningFichaSweepJob < ApplicationJob
    prepend EachCityJob
    queue_as :housekeeping

    SWEEP_HOUR = 23

    def perform
      return unless Time.current.hour == SWEEP_HOUR

      Screening.completed_screenings.joins(:attendance).merge(Attendance.open_attendances)
               .where.not(id: LediOutboxEntry.where(source_type: Ledi::ScreeningFicha::SOURCE_TYPE).select(:source_id))
               .find_each { |screening| Ledi::ScreeningFicha.generate(screening, city: Current.city) }
    end
  end
end
