# Formas JSON do TFD (contrato §2, §6; §14 T8, T9, T10).
#   case       <tfd-case>: nominal, só para a comissão e o médico autor, e só
#              depois da trilha (POST /tfd/cases/:id/read) ou como resposta de
#              uma escrita; leva o laudo (com `sigtap_name` da SIGTAP ativa) e o
#              motivo dos eventos.
#   list_item  fila da comissão e "meus pedidos": SEM dado clínico (nem laudo,
#              nem prestador, nem motivo).
module Tfd
  module Json
    module_function

    def case(tfd_case)
      report = tfd_case.report || {}
      provider = tfd_case.care_provider
      { "id" => tfd_case.id, "patient" => patient(tfd_case.patient), "status" => tfd_case.status, "version" => tfd_case.version,
        "submitted_at" => tfd_case.submitted_at&.in_time_zone&.iso8601,
        "requested_by" => { "name" => user_name(tfd_case.requester_user), "cbo" => tfd_case.requester_cbo },
        "consultation_id" => tfd_case.consultation_id, "regulation_request_id" => tfd_case.regulation_request_id,
        "report" => report_json(report),
        "destination" => Transport::Json.destination(tfd_case.transport_destination),
        "provider" => provider && { "id" => provider.id, "name" => provider.name },
        "appointment_at" => tfd_case.appointment_at&.in_time_zone&.iso8601,
        "inpatient" => Array(tfd_case.inpatient_stays).map { |stay| { "from" => stay["from"], "to" => stay["to"] } },
        "legs" => tfd_case.tfd_legs.map { |leg| leg(leg) },
        "allowances" => tfd_case.tfd_allowances.order(:created_at, :id).map { |row| allowance(row) },
        "payments" => tfd_case.tfd_payments.map { |row| payment(row) },
        "accountability" => accountability(tfd_case.tfd_accountability),
        "events" => tfd_case.tfd_case_events.includes(by_user: :professional).map { |event| event(event) },
        "trip_passengers" => trip_passengers(tfd_case) }
    end

    def list_item(tfd_case)
      { "id" => tfd_case.id, "patient" => { "display_name" => tfd_case.patient.display_name },
        "destination" => { "name" => tfd_case.transport_destination.name }, "status" => tfd_case.status,
        "submitted_at" => tfd_case.submitted_at&.in_time_zone&.iso8601 }
    end

    def patient(patient)
      { "id" => patient.id, "display_name" => patient.display_name, "birth_date" => patient.birth_date }
        .merge(Patients::IdentifierJson.call(patient).transform_keys(&:to_s))
    end

    def report_json(report)
      code = report["sigtap_code"]
      { "sigtap_code" => code, "sigtap_name" => sigtap_name(code), "cid10" => report["cid10"], "justification" => report["justification"],
        "companion_indicated" => report["companion_indicated"], "companion_reason" => report["companion_reason"],
        "transport_mode" => report["transport_mode"] }
    end

    # <tfd-leg> (§2 + T10).
    def leg(leg)
      { "id" => leg.id, "direction" => leg.direction, "mode" => leg.mode, "date" => leg.date.iso8601, "distance_km" => leg.distance_km,
        "trip_passenger_id" => leg.transport_trip_passenger_id,
        "ticket" => leg.ticket_amount_cents && { "amount_cents" => leg.ticket_amount_cents, "carrier" => leg.ticket_carrier },
        "companion" => leg.companion, "outbound_leg_id" => leg.outbound_leg_id, "done" => leg.done_at.present? }
    end

    # <tfd-allowance>
    def allowance(row)
      { "id" => row.id, "person" => row.person, "kind" => row.kind, "sigtap_code" => row.sigtap_code, "quantity" => row.quantity,
        "table_cents" => row.table_cents, "complement_cents" => row.complement_cents, "total_cents" => row.total_cents }
    end

    # <tfd-payment> (a coluna `method` vira `payment_method` na Task 12; o JSON continua "method").
    def payment(row)
      { "id" => row.id, "paid_on" => row.paid_on.iso8601, "amount_cents" => row.amount_cents,
        "method" => row.has_attribute?(:payment_method) ? row[:payment_method] : row[:method],
        "receipt_number" => row.receipt_number, "by_name" => user_name(row.by_user) }
    end

    def accountability(row)
      row && { "closed_at" => row.closed_at.in_time_zone.iso8601, "document" => { "id" => row.exam_file_id, "filename" => row.filename } }
    end

    def event(event)
      { "kind" => event.kind, "at" => event.created_at.in_time_zone.iso8601, "by_name" => event.by_user && user_name(event.by_user),
        "reason" => event.reason }
    end

    # §14 T8: passageiros ativos com origem neste processo, pela saída.
    def trip_passengers(tfd_case)
      TransportTripPassenger.active.where(tfd_case_id: tfd_case.id, origin: "tfd").joins(:transport_trip)
                            .includes(:transport_trip).order("transport_trips.departure_at", :id).map do |passenger|
        trip = passenger.transport_trip
        { "id" => passenger.id, "date" => trip.date.iso8601, "departure_at" => trip.departure_at.in_time_zone.iso8601,
          "attendance" => passenger.attendance, "companion_attendance" => passenger.companion_attendance }
      end
    end

    # Nome do procedimento na SIGTAP ativa da competência de hoje; nil se falta.
    def sigtap_name(code)
      return nil unless code.is_a?(String)

      release = Terminology::Sigtap.release_for(Time.zone.today.strftime("%Y%m"))
      release && SigtapProcedure.where(release_id: release.id, code: code).pick(:name)
    end

    def user_name(user) = Screenings::Json.staff_name(user)
  end
end
