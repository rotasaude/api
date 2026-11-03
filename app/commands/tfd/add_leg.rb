# POST /tfd/cases/:id/legs (contrato §6; plano, Desvio 13; §14 T10, T18),
# pela comissão: `{ direction, mode, date, trip_passenger_id?, ticket?, companion? }`.
#   - frota: `trip_passenger_id` de um passageiro ATIVO do mesmo paciente,
#     `origin: "tfd"` e `tfd_case_id` deste processo, numa viagem não
#     cancelada, ainda sem trecho NESTE sentido (a linha leva a ida e/ou a
#     volta, T38); `date` = a da viagem (ida: trip.date; volta: dia local de
#     return_at), senão `invalid_request` em `date`; sem `ticket` e sem
#     acompanhante (a presença do acompanhante vem da viagem) — senão
#     `invalid_request` no campo;
#   - passagem (`bus_ticket`, `air`, `river`): `ticket: { amount_cents
#     (1..10_000_000), carrier (1..CARRIER_MAX = 120, T18) }`, sem `trip_passenger_id`;
#     `companion: true` só com o acompanhante indicado no laudo
#     (`companion_not_allowed`, como no passageiro do TFD, Desvio 5);
#   - a volta pareia com a ida mais antiga sem volta e com data ≤ a dela
#     (`outbound_leg_id`); sem ida aberta → `no_outbound_leg`; mais de
#     Catalog::MAX_NIGHTS (999) noites depois da ida → `invalid_request` em
#     `date` (a quantidade da alimentação no BPA vai até 999; Task 13 I1).
# Recusas de forma todas de uma vez. Processo em authorized/scheduled/
# travelling (senão `invalid_transition`); o primeiro trecho move authorized →
# scheduled. `distance_km` copiado do destino. Trecho de frota registrado com
# a viagem já fechada e o paciente `boarded` nasce feito (Tfd::FleetLegs).
# Travas: viagem (frota) → processo, a mesma ordem do fechamento. Publica
# tfd.leg_added (tfd_case_id, tfd_leg_id, user_id).
module Tfd
  module AddLeg
    OPEN = %w[authorized scheduled travelling].freeze
    KEYS = %w[direction mode date trip_passenger_id ticket companion].freeze
    TICKET_KEYS = %w[amount_cents carrier].freeze
    CARRIER = (1..Catalog::CARRIER_MAX)
    AMOUNT = (1..Catalog::MAX_AMOUNT_CENTS)
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    KEY_PATH_MAX = 64

    module_function

    # -> Result.ok(leg:) | fail(:missing_role | :invalid_request | :invalid_transition | :no_outbound_leg |
    #    :companion_not_allowed, path:, problems:)
    def call(tfd_case:, attrs:, by:)
      return Result.fail(:missing_role) unless Access.committee?(by)

      attrs = attrs.to_h.stringify_keys
      fields, paths = parse(attrs)
      return Transport::Support.refuse(paths) if paths.any?

      TfdCase.transaction(requires_new: true) do
        rider, trip = lock_rider(fields[:trip_passenger_id]) if fields[:mode] == "fleet"
        tfd_case.lock!
        next Result.fail(:invalid_transition) unless OPEN.include?(tfd_case.status)
        if fields[:mode] == "fleet"
          next Transport::Support.refuse([ "trip_passenger_id" ]) unless rider_ok?(rider, trip, tfd_case, fields[:direction])
          next Transport::Support.refuse([ "date" ]) unless fields[:date] == fleet_date(trip, fields[:direction])
        end
        if fields[:companion] && tfd_case.report.to_h["companion_indicated"] != true
          next Transport::Support.refuse_with(:companion_not_allowed, "companion")
        end

        outbound = nil
        if fields[:direction] == "return"
          outbound = open_outbound(tfd_case, fields[:date])
          next Transport::Support.refuse_with(:no_outbound_leg, "direction") unless outbound
          next Transport::Support.refuse([ "date" ]) if (fields[:date] - outbound.date).to_i > Catalog::MAX_NIGHTS
        end

        leg = TfdLeg.create!(tfd_case: tfd_case, direction: fields[:direction], mode: fields[:mode], date: fields[:date],
                             distance_km: tfd_case.transport_destination.distance_km, transport_trip_passenger: rider,
                             ticket_amount_cents: fields[:amount_cents], ticket_carrier: fields[:carrier],
                             companion: fields[:companion] || false, outbound_leg: outbound, created_by_user: by)
        if tfd_case.status == "authorized"
          moved = Transition.call(tfd_case: tfd_case, to: "scheduled", by: by)
          raise "tfd: authorized → scheduled refused" if moved.failure? # inalcançável: conferida sob a trava
        end
        DomainEvents.publish("tfd.leg_added", tfd_case_id: tfd_case.id, tfd_leg_id: leg.id, user_id: by.id)
        FleetLegs.complete_passenger!(rider, by: by) if rider && trip.status == "done" # completa os trechos abertos da linha
        Result.ok(leg: leg.reload)
      end
    end

    # -> [ { direction:, mode:, date:, trip_passenger_id:, amount_cents:, carrier:, companion: }, [paths] ]
    def parse(attrs)
      paths = (attrs.keys - KEYS).map { |key| key.to_s[0, KEY_PATH_MAX] }
      direction = attrs["direction"]
      mode = attrs["mode"]
      paths << "direction" unless Catalog::DIRECTIONS.include?(direction)
      paths << "mode" unless Catalog::MODES.include?(mode)
      date = Transport::Support.date(attrs["date"])
      paths << "date" unless date
      companion = attrs["companion"]
      paths << "companion" unless companion.nil? || Transport::Support.boolean?(companion)
      fields = { direction: direction, mode: mode, date: date, companion: companion == true }

      if mode == "fleet"
        id = attrs["trip_passenger_id"]
        if id.is_a?(String) && id.match?(UUID)
          fields[:trip_passenger_id] = id
        else
          paths << "trip_passenger_id"
        end
        paths << "ticket" unless attrs["ticket"].nil?
        paths << "companion" if companion == true
      elsif Catalog::MODES.include?(mode)
        paths << "trip_passenger_id" unless attrs["trip_passenger_id"].nil?
        ticket(attrs["ticket"], fields, paths)
      end
      [ fields, paths.uniq ]
    end

    def ticket(value, fields, paths)
      return paths << "ticket" unless value.is_a?(Hash)

      value = value.stringify_keys
      paths.concat((value.keys - TICKET_KEYS).map { |key| "ticket.#{key.to_s[0, KEY_PATH_MAX]}" })
      fields[:amount_cents] = Transport::Support.integer(value["amount_cents"], AMOUNT)
      paths << "ticket.amount_cents" unless fields[:amount_cents]
      fields[:carrier] = Transport::Support.text(value["carrier"], CARRIER)
      paths << "ticket.carrier" unless fields[:carrier]
    end

    # Viagem travada antes do processo (a ordem do fechamento). -> [passageiro, viagem] | [nil, nil]
    def lock_rider(id)
      rider = TransportTripPassenger.find_by(id: id)
      return [ nil, nil ] unless rider

      trip = TransportTrip.lock.find(rider.transport_trip_id)
      [ rider.reload, trip ]
    end

    # Um trecho por (passageiro, sentido): a mesma linha leva a ida e a volta da viagem (T38).
    def rider_ok?(rider, trip, tfd_case, direction)
      rider.present? && !rider.removed? && rider.anonymized_at.nil? && trip.status != "cancelled" &&
        rider.origin == "tfd" && rider.tfd_case_id == tfd_case.id && rider.patient_id == tfd_case.patient_id &&
        !TfdLeg.exists?(transport_trip_passenger_id: rider.id, direction: direction)
    end

    # Data do trecho de frota vem da viagem (T38): ida → trip.date; volta → dia local da chegada.
    def fleet_date(trip, direction) = direction == "return" ? trip.return_at.in_time_zone.to_date : trip.date

    # Ida mais antiga sem volta, com data ≤ a da volta.
    def open_outbound(tfd_case, date)
      paired = TfdLeg.where(tfd_case_id: tfd_case.id).where.not(outbound_leg_id: nil).select(:outbound_leg_id)
      TfdLeg.where(tfd_case_id: tfd_case.id, direction: "outbound").where(date: ..date).where.not(id: paired)
            .order(:date, :created_at, :id).first
    end
    private_class_method :parse, :ticket, :lock_rider, :rider_ok?, :fleet_date, :open_outbound
  end
end
