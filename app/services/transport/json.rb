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

    # Como a fila do módulo 13: nome profissional; sem perfil, o e-mail.
    def user_name(user) = Screenings::Json.staff_name(user)

    def license_status(expires_on, today)
      return "expired" if expires_on < today

      expires_on <= today + Catalog::LICENSE_WARNING_DAYS ? "expiring" : "valid"
    end
  end
end
