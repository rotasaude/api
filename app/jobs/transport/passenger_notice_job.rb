# Aviso de viagem de UM passageiro (ADR 0048; §14 T15; Ruling I-1), repartido
# pelo Transport::NoticeJob: o Transport::Notify numa transação só dele (o
# índice único dos avisos é a idempotência — a nova tentativa não duplica nem
# reenvia o SMS de quem já recebeu). Com o transporte desligado (lido fora da
# transação da cidade), nada. Cidade desconhecida → CityMissing (D7: falha
# visível, nunca um aviso perdido em silêncio). Só ids e códigos nos argumentos.
module Transport
  class PassengerNoticeJob < ApplicationJob
    include CityScopedJob
    queue_as :default

    def perform(city_slug:, passenger_id:, kind:, event_key: "once")
      city = City.find_by(slug: city_slug)
      raise CityScopedJob::CityMissing, "#{self.class.name}: cidade #{city_slug} não existe" unless city
      return unless Gate.usable?(city)

      with_city(city_slug) do
        passenger = TransportTripPassenger.find_by(id: passenger_id)
        Notify.call(passenger: passenger, kind: kind, event_key: event_key) if passenger
      end
    end
  end
end
