# Texto do SMS do aviso de viagem (ADR 0048; contrato §8; §14 T15; D14): um
# texto fixo por evento, com o prefixo do lembrete do 17 ("Secretaria de Saúde
# de <cidade>: "). Data `dd/mm` e hora `HH:MM` no fuso da cidade; o embarque é
# o rótulo da parada do passageiro, cortado em 40 caracteres na última palavra
# inteira. Nunca o destino, o prestador nem dado do paciente — aparece na tela
# de bloqueio.
module Transport
  module SmsText
    PREFIX = "Secretaria de Saúde de %{city}: ".freeze
    DEPARTURE = "sua viagem de %{date} sai às %{time} de %{boarding}.".freeze
    CANCELLED = "sua viagem de %{date} foi cancelada. Veja em %{link}".freeze
    TEXTS = {
      "added" => DEPARTURE, "departure_changed" => DEPARTURE, "boarding_changed" => DEPARTURE, "reminder" => DEPARTURE,
      "cancelled" => CANCELLED, "removed" => CANCELLED
    }.freeze
    BOARDING_MAX = 40

    module_function

    def body(kind:, passenger:)
      departure = passenger.transport_trip.departure_at.in_time_zone
      format(PREFIX + TEXTS.fetch(kind.to_s),
             city: CityProfile.current&.name.presence || Current.city.name,
             date: departure.strftime("%d/%m"), time: departure.strftime("%H:%M"),
             boarding: boarding(passenger.transport_trip_stop.label),
             link: Campaigns::SmsText.link(Current.city))
    end

    def boarding(label) = label.to_s.squish.truncate(BOARDING_MAX, separator: " ", omission: "")
  end
end
