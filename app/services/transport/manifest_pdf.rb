# Lista de passageiros impressa da viagem (ADR 0048; contrato §4, T18). A4 da
# folha de Consultations::Print.document, com rodapé próprio. SEM dado clínico
# e SEM CPF/CNS: só nome, embarque, destino (município e prestador), hora do
# atendimento, acompanhante (nome) e cadeira de rodas. Nunca procedimento,
# especialidade, CID, texto do pedido nem o alvo do pedido de origem. Passageiro
# retirado não entra. Gera bytes; nada é gravado nem logado.
module Transport
  module ManifestPdf
    module_function

    Footer = Data.define(:text)
    FOOTER = Footer.new("Lista de passageiros do transporte sanitário. Documento de uso interno: não contém dado clínico.").freeze
    TITLE = "Lista de passageiros".freeze

    # -> String (bytes do PDF)
    def call(trip)
      pdf = Consultations::Print.document(FOOTER, title: TITLE)
      header(pdf, trip)
      stops(trip).each { |stop| stop_block(pdf, stop, passengers_by_stop(trip)[stop.id] || []) }
      pdf.render
    end

    def header(pdf, trip)
      vehicle = trip.transport_vehicle
      driver = trip.transport_driver
      pdf.text s(CityProfile.current&.name.to_s), style: :bold, size: 12
      pdf.text s(TITLE.upcase), style: :bold, size: 13
      pdf.text s("Data: #{trip.date.strftime('%d/%m/%Y')}")
      pdf.text s("Saída: #{hour(trip.departure_at)}    Retorno: #{hour(trip.return_at)}")
      pdf.text s("Veículo: #{vehicle ? "#{vehicle.plate} — #{vehicle.model}" : 'a definir'}")
      pdf.text s("Motorista: #{driver ? Json.user_name(driver.user) : 'a definir'}")
    end

    def stop_block(pdf, stop, passengers)
      pdf.move_down 10
      pdf.text s("Embarque: #{stop.label}"), style: :bold, size: 11
      return pdf.text(s("Nenhum passageiro nesta parada."), size: 9) if passengers.empty?

      passengers.each { |passenger| line(pdf, passenger) }
    end

    def line(pdf, passenger)
      destination = passenger.transport_destination
      place = [ destination.name, passenger.provider_name.presence ].compact.join(" — ")
      pdf.move_down 6
      pdf.text s("#{passenger.patient.display_name}#{passenger.wheelchair ? '  (cadeira de rodas)' : ''}"), style: :bold
      pdf.text s("Destino: #{place}    Hora do atendimento: #{passenger.appointment_at ? hour(passenger.appointment_at) : 'não informada'}")
      pdf.text s("Acompanhante: #{passenger.companion_name}") if passenger.companion_name
      pdf.text s("Assinatura no embarque: ______________________________________"), size: 9
    end

    def stops(trip) = trip.transport_trip_stops.select { |stop| stop.kind == "boarding" }.sort_by(&:position)

    def passengers_by_stop(trip)
      trip.transport_trip_passengers.active.includes(:patient, :transport_destination).order(:created_at, :id).group_by(&:transport_trip_stop_id)
    end

    def hour(time) = time.in_time_zone.strftime("%H:%M")
    def s(text) = Consultations::Print.safe(text)
  end
end
