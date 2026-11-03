# POST /transport/trips/:id/attendance_correction { items, reason } (contrato
# §5; plano, Desvio 9; §14 T18, T23; Review Focus 5): a central corrige a
# presença de viagem `done` (o trigger a congela no fechamento). `items` =
# `[ { passenger_id, attendance, companion_attendance? } ]` só com `boarded`
# ou `no_show`; motivo 10..500 (cifrado). Tudo ou nada; uma linha de
# transport_attendance_corrections por campo que de fato muda (o item igual
# ao gravado não gera linha). Recusas:
#   - viagem fora de `done` → `invalid_transition`;
#   - passageiro que não é ativo desta viagem → not_found;
#   - passageiro anonimizado (LGPD, linha congelada) → `passenger_anonymized`;
#   - passageiro cujo trecho de frota do TFD já está `done` → `tfd_leg_done`
#     (a ajuda de custo e a linha do BPA já nasceram da presença gravada; vale
#     para qualquer campo que mude, paciente ou acompanhante).
# Só o UPDATE e o INSERT da correção correm sob
# TransportTripPassenger.with_attendance_correction (a trava volta ao sair).
# Depois, `no_show` → `boarded` chama Tfd::FleetLegs.complete_passenger! (a
# viagem já travada aqui: a mesma trava que o fechamento segura — Ruling da
# Task 8), que só completa trecho vivo: o trecho que o fechamento anulou por
# no_show (FR I1) fica anulado, e a comissão registra o trecho de frota de
# novo na mesma linha (nasce feito, com o paciente boarded). Evento transport.attendance_corrected
# (trip_id e os ids dos passageiros mudados), só quando algo mudou.
module Transport
  module CorrectAttendance
    STATUSES = %w[boarded no_show].freeze
    FIELDS = %i[attendance companion_attendance].freeze

    module_function

    # -> Result.ok(trip:) | fail(:invalid_request | :tfd_leg_done, details: { path:, problems: }) |
    #    fail(:invalid_transition | :not_found | :passenger_anonymized)
    def call(trip:, items:, reason:, by:)
      list, problems = AttendanceItems.parse(items, statuses: STATUSES)
      text = Support.text(reason, Catalog::REASON)
      problems << "reason" unless text
      return Support.refuse(problems) if problems.any?

      TransportTrip.transaction(requires_new: true) do
        trip.lock!
        next Result.fail(:invalid_transition) unless trip.status == "done"

        passengers = AttendanceItems.load(trip, list)
        next Result.fail(:not_found) unless passengers
        next Result.fail(:passenger_anonymized) if passengers.values.any?(&:anonymized_at)

        problems = AttendanceItems.companion_problems(list, passengers)
        next Support.refuse(problems) if problems.any?

        changes = list.to_h { |item| [ item, changes_for(item, passengers.fetch(item.passenger_id)) ] }.reject { |_, c| c.empty? }
        done_legs = TfdLeg.where(transport_trip_passenger_id: changes.keys.map(&:passenger_id), mode: "fleet").where.not(done_at: nil)
                          .pluck(:transport_trip_passenger_id).to_set
        blocked = changes.keys.find { |item| done_legs.include?(item.passenger_id) }
        if blocked
          next Support.refuse_with(:tfd_leg_done, "items.#{blocked.index}.#{changes[blocked].keys.first}")
        end
        next Result.ok(trip: trip) if changes.empty?

        write!(changes, passengers, text, by)
        changes.each do |item, fields|
          next unless fields[:attendance] == %w[no_show boarded]

          Tfd::FleetLegs.complete_passenger!(passengers.fetch(item.passenger_id), by: by)
        end
        DomainEvents.publish("transport.attendance_corrected", trip_id: trip.id, passenger_ids: changes.keys.map(&:passenger_id))
        Result.ok(trip: trip)
      end
    end

    # { field => [from, to] } dos campos mandados que mudam.
    def changes_for(item, passenger)
      FIELDS.each_with_object({}) do |field, acc|
        to = item.public_send(field)
        from = passenger.public_send(field)
        acc[field] = [ from, to ] if to && from != to
      end
    end

    # Só o UPDATE e o INSERT da correção sob a trava desligada.
    def write!(changes, passengers, reason, by)
      TransportTripPassenger.with_attendance_correction do
        changes.each do |item, fields|
          passenger = passengers.fetch(item.passenger_id)
          passenger.update!(fields.transform_values(&:last))
          fields.each do |field, (from, to)|
            TransportAttendanceCorrection.create!(transport_trip_passenger: passenger, field: field.to_s, from_value: from, to_value: to,
                                                  reason: reason, by_user: by)
          end
        end
      end
    end
  end
end
