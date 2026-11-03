# Formas JSON do transporte sanitário (contrato §2; ADR 0048). Frota, motoristas
# e destinos: nada de paciente. A CNH nunca sai inteira, só `license_number_last4`.
module Transport
  module Json
    module_function

    # <vehicle>
    def vehicle(v)
      { "id" => v.id, "plate" => v.plate, "renavam" => v.renavam, "model" => v.model, "kind" => v.kind, "renem_code" => v.renem_code,
        "seats" => v.seats, "wheelchair_spots" => v.wheelchair_spots, "cnes" => v.cnes, "active" => v.active }
    end

    # <driver>: `license_status` — expired (vencida), expiring (vence em até 30
    # dias, inclusive hoje) ou valid. O usuário só leva id e nome.
    def driver(d, today: Time.zone.today)
      number = d.license_number.to_s
      { "id" => d.id, "user" => { "id" => d.user_id, "name" => user_name(d.user) }, "license_category" => d.license_category,
        "license_expires_on" => d.license_expires_on.iso8601, "license_status" => license_status(d.license_expires_on, today),
        "license_number_last4" => number.last(4), "active" => d.active }
    end

    # <destination>
    def destination(d)
      { "id" => d.id, "ibge_code" => d.ibge_code, "name" => d.name, "distance_km" => d.distance_km,
        "metropolitan" => d.metropolitan, "active" => d.active }
    end

    # <trip> (contrato §2): horas ISO no fuso da cidade; veículo resumido,
    # motorista só id e nome (nunca a CNH). `viewer` (:dispatcher | :driver)
    # escolhe a forma do passageiro (Transport::Json.passenger); o `log` entra
    # com o fechamento (Task 8).
    def trip(trip, viewer: :dispatcher)
      vehicle = trip.transport_vehicle
      driver = trip.transport_driver
      { "id" => trip.id, "date" => trip.date.iso8601, "departure_at" => trip.departure_at.in_time_zone.iso8601,
        "return_at" => trip.return_at.in_time_zone.iso8601,
        "vehicle" => vehicle && { "id" => vehicle.id, "plate" => vehicle.plate, "model" => vehicle.model, "kind" => vehicle.kind,
                                  "seats" => vehicle.seats, "wheelchair_spots" => vehicle.wheelchair_spots },
        "driver" => driver && { "id" => driver.id, "name" => user_name(driver.user) },
        "status" => trip.status,
        "stops" => trip.transport_trip_stops.sort_by(&:position).map { |stop| stop(stop) },
        "passengers" => passengers(trip, viewer),
        "occupancy" => Occupancy.of(trip, vehicle: vehicle).transform_keys(&:to_s),
        "series_id" => trip.transport_series_id, "log" => nil }
    end

    def stop(stop)
      { "id" => stop.id, "position" => stop.position, "kind" => stop.kind, "destination_id" => stop.transport_destination_id,
        "label" => stop.label }
    end

    # Passageiros ativos (não retirados) na forma <passenger>, por ordem de entrada.
    def passengers(trip, viewer)
      trip.transport_trip_passengers.active.includes(:patient, :transport_destination).order(:created_at, :id)
          .map { |passenger| passenger(passenger, viewer: viewer) }
    end

    # <passenger> (contrato §2 + T18: o destino leva o nome do município).
    # SEM dado clínico: nunca procedimento, especialidade, CID, laudo nem o
    # texto do pedido; o CPF nunca sai (só `has_cpf`), o CNS só mascarado e o
    # documento do acompanhante só os 4 últimos. O motorista (viewer: :driver)
    # não recebe `has_cpf` nem `cns_masked`.
    def passenger(p, viewer: :dispatcher)
      destination = p.transport_destination
      { "id" => p.id, "patient" => patient(p.patient, viewer: viewer), "stop_id" => p.transport_trip_stop_id,
        "destination" => { "destination_id" => destination.id, "name" => destination.name, "provider_name" => p.provider_name,
                           "address" => p.address },
        "appointment_at" => p.appointment_at&.in_time_zone&.iso8601, "takes_seat" => p.takes_seat, "wheelchair" => p.wheelchair,
        "companion" => p.companion_name && { "name" => p.companion_name, "document_last4" => p.companion_document&.last(4) },
        "origin" => p.origin, "exception_reason" => p.exception_reason, "attendance" => p.attendance,
        "companion_attendance" => p.companion_attendance }
    end

    # O paciente no <passenger> e no item dos atendimentos marcados: telefone
    # mascarado do primeiro par validado (Patients::Pairs).
    def patient(patient, viewer: :dispatcher)
      phone = Patients::Pairs.of(patient).order(:created_at, :id).first&.phone
      base = { "id" => patient.id, "display_name" => patient.display_name }
      ids = viewer == :driver ? {} : Patients::IdentifierJson.call(patient).transform_keys(&:to_s)
      base.merge(ids).merge("phone_masked" => phone && CitizenIdentity::Phone.mask(phone))
    end

    # <series> (§14 T6; preflight §3): os campos da escrita + `status`
    # (TransportSeries#status_on: suspended | ended | active) e
    # `suspended_from`. O paciente só id e nome; o documento do acompanhante
    # só os 4 últimos; o motivo do acompanhante e o da suspensão nunca saem.
    def series(s, today: Time.zone.today)
      destination = s.transport_destination
      { "id" => s.id, "patient" => { "id" => s.patient_id, "display_name" => s.patient.display_name },
        "destination" => { "id" => destination.id, "name" => destination.name }, "provider_name" => s.provider_name,
        "weekdays" => s.weekdays, "appointment_time" => s.clock(:appointment_time), "departure_time" => s.clock(:departure_time),
        "return_time" => s.clock(:return_time), "boarding_label" => s.boarding_label, "starts_on" => s.starts_on.iso8601,
        "ends_on" => s.ends_on&.iso8601, "wheelchair" => s.wheelchair,
        "companion" => s.companion_name && { "name" => s.companion_name, "document_last4" => s.companion_document&.last(4) },
        "status" => s.status_on(today), "suspended_from" => s.suspended_from&.iso8601 }
    end

    # Como a fila do módulo 13: nome profissional; sem perfil, o e-mail.
    def user_name(user) = Screenings::Json.staff_name(user)

    def license_status(expires_on, today)
      return "expired" if expires_on < today

      expires_on <= today + Catalog::LICENSE_WARNING_DAYS ? "expiring" : "valid"
    end
  end
end
