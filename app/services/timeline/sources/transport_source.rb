# Transporte sanitário e TFD na linha do tempo (ADR 0048; contrato §9; §14 T1).
# Duas origens, o mesmo kind "transport":
#   - passageiro `boarded`, não retirado, de viagem não cancelada: source_id =
#     passageiro, occurred_at = saída da viagem (departure_at; nunca o
#     fechamento), título "Viagem para <cidade>" ou, com origem tfd,
#     "TFD para <cidade>" (a cidade do destino do passageiro);
#   - trecho de PASSAGEM do TFD feito (bus_ticket/air/river): source_id =
#     trecho, occurred_at = meio-dia local da data do trecho (a passagem não
#     tem hora), título "TFD para <cidade do processo>". O trecho de frota não
#     entra em separado: já é o passageiro da viagem.
# Falta, pendente, retirado e viagem cancelada ficam fora. Sem tela de
# detalhe: detail_ref, unidade, profissional (nunca o motorista), situação,
# resumo e documento nulos nas duas visões.
#
# NÃO consulta os interruptores: viagem feita é registro retido (como a
# vacina). Vazia sem paciente. A trilha é do controlador.
module Timeline
  module Sources
    module TransportSource
      KIND = "transport".freeze
      TICKET_MODES = (::Tfd::Catalog::MODES - %w[fleet]).freeze

      module_function

      def entries(person:, before:, limit:, from:, to:)
        return [] unless person.patient_id

        rows = passengers(person.patient_id, before, limit, from, to) + legs(person.patient_id, before, limit, from, to)
        rows.sort_by(&:sort_key).first(limit)
      end

      def passengers(patient_id, before, limit, from, to)
        scope = ::TransportTripPassenger.active.where(patient_id: patient_id, attendance: "boarded")
                                        .joins(:transport_trip).where.not(transport_trips: { status: "cancelled" })
                                        .includes(:transport_trip, :transport_destination)
        Window.apply(scope, kind: KIND, column: "transport_trips.departure_at", id_column: "transport_trip_passengers.id",
                            before: before, from: from, to: to).limit(limit).map do |rider|
          prefix = rider.origin == "tfd" ? "TFD para" : "Viagem para"
          entry(rider.id, rider.transport_trip.departure_at, "#{prefix} #{rider.transport_destination.name}")
        end
      end
      private_class_method :passengers

      def legs(patient_id, before, limit, from, to)
        noon = noon_sql
        scope = ::TfdLeg.joins(:tfd_case).where(tfd_cases: { patient_id: patient_id }, mode: TICKET_MODES).where.not(done_at: nil)
                        .includes(tfd_case: :transport_destination)
        Window.apply(scope, kind: KIND, column: noon, id_column: "tfd_legs.id", before: before, from: from, to: to)
              .limit(limit).map do |leg|
          entry(leg.id, Time.zone.parse("#{leg.date.iso8601} 12:00"), "TFD para #{leg.tfd_case.transport_destination.name}")
        end
      end
      private_class_method :legs

      # Meio-dia local da data do trecho, como timestamp UTC sem fuso (o mesmo
      # tipo das colunas datetime), para a janela e o cursor no SQL.
      def noon_sql
        zone = ApplicationRecord.connection.quote(Time.zone.tzinfo.identifier)
        "(((tfd_legs.date + TIME '12:00') AT TIME ZONE #{zone}) AT TIME ZONE 'UTC')"
      end
      private_class_method :noon_sql

      def entry(source_id, at, title)
        Entry.new(kind: KIND, source_id: source_id, occurred_at: at, unit: nil, professional: nil, title: title, summary: nil,
                  status: nil, detail_ref: nil,
                  citizen: { title: title, summary: nil, status: nil, professional_name: nil, unit: nil }, document: nil)
      end
      private_class_method :entry
    end
  end
end
