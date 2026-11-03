# Lembrete da véspera da viagem confirmada (ADR 0048; Desvio 8; §14 T15),
# cidade por cidade, com `sanitary_transport` utilizável (lido fora de
# transação da cidade). Roda a cada 15 minutos e só age das 17h às 20h no fuso
# da cidade (CityConnection.with usa o fuso dela), como o lembrete do 17. Um
# `reminder` por passageiro ativo e par (Transport::Notify; o índice único
# faz a próxima rodada não repetir).
module Transport
  class RemindJob < ApplicationJob
    prepend EachCityJob
    queue_as :housekeeping

    FROM_HOUR = Appointments::RemindJob::FROM_HOUR

    def perform
      return unless Gate.usable?(Current.city)

      now = Time.current
      return unless now.hour >= FROM_HOUR && Campaigns::SmsBatchJob::WINDOW_HOURS.cover?(now.hour)

      TransportTripPassenger.active.where(anonymized_at: nil).joins(:transport_trip)
                            .where(transport_trips: { status: "confirmed", date: now.to_date + 1 }).find_each do |passenger|
        Notify.call(passenger: passenger, kind: "reminder", now: now)
      end
    end
  end
end
