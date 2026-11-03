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
    # escolhe a forma do passageiro; os passageiros entram com o
    # Transport::Json.passenger (Task 5) e o `log` com o fechamento (Task 8).
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

    # Passageiros ativos na forma <passenger>: o Transport::Json.passenger
    # nasce na Task 5, que troca este corpo; até lá a lista sai vazia.
    def passengers(_trip, _viewer) = []

    # Como a fila do módulo 13: nome profissional; sem perfil, o e-mail.
    def user_name(user) = Screenings::Json.staff_name(user)

    def license_status(expires_on, today)
      return "expired" if expires_on < today

      expires_on <= today + Catalog::LICENSE_WARNING_DAYS ? "expiring" : "valid"
    end
  end
end
