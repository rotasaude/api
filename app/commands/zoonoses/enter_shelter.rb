# Entrada no canil ou gatil (módulo 35b, ADR 0054; contrato §1, §7, Q16, Q31).
# Corpo: `animal_id` OU `new_animal` (exatamente um, senão invalid_request path
# animal_id / new_animal), `health_unit_id` (unidade environmental_surveillance
# ativa), `entry_kind` (Catalog::ENTRY_KINDS), `entered_on` (opcional,
# "AAAA-MM-DD", padrão hoje; depois de hoje → date_out_of_range) e
# `bite_observation_id` (só e sempre com entry_kind observation). Toda recusa
# de campo é invalid_request com o path.
#
#   - Quem: team? (senão missing_role).
#   - `new_animal`: o corpo de criação do Zoonoses::SaveAnimal sem tutor nem
#     domicílio (`tutor_patient_id` / `household_id` → path
#     new_animal.<chave>); o animal nasce na mesma transação da estada (as
#     recusas do SaveAnimal voltam com o path prefixado new_animal.).
#   - `animal_id`: o animal FOR UPDATE (a primeira trava, a mesma ordem das
#     quatro escritas do canil: animal → estada → coleira → observação);
#     transferred ou deceased → 409 animal_not_active; missing volta a active
#     com status_on = entered_on, na mesma transação (Q31; `animal.changed`);
#     entered_on antes do cadastro do animal (o dia da cidade) → 422
#     date_out_of_range path entered_on, como o status_on da SaveAnimal.
#   - Uma estada aberta por animal → 409 stay_already_open (também na corrida,
#     pelo índice único parcial idx_shelter_stays_open).
#   - observation: a observação FOR UPDATE, `open` (senão path
#     bite_observation_id) e do mesmo animal; ligada a outro animal → 409
#     observation_changed. Grava nela place shelter (Q16) e, se ainda sem
#     animal, liga o animal da entrada (o trigger aceita de NULL a valor, uma
#     vez), version + 1.
#
# `shelter_stay.opened` só com o id. Nada do tutor em Result.details.
module Zoonoses
  module EnterShelter
    EVENT = "shelter_stay.opened".freeze
    KEYS = %w[animal_id new_animal health_unit_id entry_kind entered_on bite_observation_id].freeze
    NEW_ANIMAL_FORBIDDEN = %w[tutor_patient_id household_id].freeze
    OPEN_INDEX = "idx_shelter_stays_open".freeze
    UNIT_KIND = Access::UNIT_KIND
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    DATE = /\A\d{4}-\d{2}-\d{2}\z/
    KEY_PATH_MAX = 64

    # Recusa depois de uma escrita (o animal novo): desfaz o savepoint.
    class Refused < StandardError
      attr_reader :result

      def initialize(result)
        @result = result
        super("refused")
      end
    end

    module_function

    # -> Result.ok(stay:, animal:) | fail(:invalid_request | :date_out_of_range, details: { path: }) |
    #    fail(:missing_role | :animal_not_active | :stay_already_open | :observation_changed)
    def call(params:, by:, today: Time.zone.today)
      return Result.fail(:missing_role) unless Access.team?(by)

      params = params.to_h.stringify_keys
      attrs = parse(params, today)
      return attrs if attrs.is_a?(Result)

      ShelterStay.transaction(requires_new: true) { record(attrs, by) }
    rescue Refused => e
      e.result
    rescue ActiveRecord::RecordNotUnique => e
      raise unless e.message.include?(OPEN_INDEX)

      Result.fail(:stay_already_open)
    end

    def record(attrs, by)
      return invalid("health_unit_id") unless HealthUnit.exists?(id: attrs[:health_unit_id], kind: UNIT_KIND, active: true)

      animal = attrs[:new_animal] ? create_animal(attrs[:new_animal], by) : Animal.lock.find_by(id: attrs[:animal_id])
      return invalid("animal_id") unless animal
      return Result.fail(:animal_not_active) unless SaveAnimal::TRANSITIONS.key?(animal.status)
      refuse!(Result.fail(:stay_already_open)) if ShelterStay.open_stays.exists?(animal_id: animal.id)

      observation = observation!(attrs[:bite_observation_id], animal) if attrs[:entry_kind] == "observation"
      if animal.status == "missing"
        # Como na SaveAnimal: status_on entre o cadastro do animal (o dia da cidade) e hoje.
        unless (animal.created_at.in_time_zone.to_date..Time.zone.today).cover?(attrs[:entered_on])
          refuse!(Result.fail(:date_out_of_range, details: { path: "entered_on" }))
        end
        animal.update!(status: "active", status_on: attrs[:entered_on], version: animal.version + 1)
        DomainEvents.publish("animal.changed", animal_id: animal.id)
      end
      stay = ShelterStay.create!(animal: animal, health_unit_id: attrs[:health_unit_id], entry_kind: attrs[:entry_kind],
                                 entered_on: attrs[:entered_on], bite_observation: observation)
      observation&.update!(place: "shelter", animal_id: observation.animal_id || animal.id, version: observation.version + 1)
      DomainEvents.publish(EVENT, shelter_stay_id: stay.id)
      Result.ok(stay: stay, animal: animal)
    end

    def create_animal(body, by)
      created = SaveAnimal.call(params: body, by: by)
      if created.failure?
        path = created.details[:path]
        refuse!(Result.fail(created.reason, details: path ? { path: "new_animal.#{path}" } : created.details))
      end
      created.payload.fetch(:animal)
    end

    def observation!(id, animal)
      observation = BiteObservation.lock.find_by(id: id)
      refuse!(invalid("bite_observation_id")) unless observation&.state == "open"
      refuse!(Result.fail(:observation_changed)) unless [ nil, animal.id ].include?(observation.animal_id)
      observation
    end

    # Forma do corpo. -> { atributo => valor } | Result de recusa (só a primeira).
    def parse(params, today)
      unknown = params.keys.find { |key| !KEYS.include?(key) }
      return invalid(unknown.to_s[0, KEY_PATH_MAX]) if unknown
      return invalid("new_animal") if params.key?("new_animal") && params.key?("animal_id")

      attrs = {}
      if params.key?("new_animal")
        body = params["new_animal"]
        return invalid("new_animal") unless body.is_a?(Hash)

        forbidden = body.keys.map(&:to_s).find { |key| NEW_ANIMAL_FORBIDDEN.include?(key) }
        return invalid("new_animal.#{forbidden}") if forbidden

        attrs[:new_animal] = body
      else
        return invalid("animal_id") unless uuid?(params["animal_id"])

        attrs[:animal_id] = params["animal_id"].downcase
      end
      return invalid("health_unit_id") unless uuid?(params["health_unit_id"])
      return invalid("entry_kind") unless Catalog::ENTRY_KINDS.include?(params["entry_kind"])

      attrs[:health_unit_id] = params["health_unit_id"].downcase
      attrs[:entry_kind] = params["entry_kind"]
      observation = attrs[:entry_kind] == "observation"
      return invalid("bite_observation_id") if observation ? !uuid?(params["bite_observation_id"]) : params.key?("bite_observation_id")

      attrs[:bite_observation_id] = params["bite_observation_id"].downcase if observation
      entered_on = params.key?("entered_on") ? date(params["entered_on"]) : today
      return invalid("entered_on") unless entered_on
      return Result.fail(:date_out_of_range, details: { path: "entered_on" }) if entered_on > today

      attrs.merge(entered_on: entered_on)
    end

    def date(value)
      value.is_a?(String) && value.match?(DATE) ? Date.strptime(value, "%Y-%m-%d") : nil
    rescue Date::Error
      nil
    end

    def uuid?(value) = value.is_a?(String) && value.match?(UUID)
    def invalid(path) = Result.fail(:invalid_request, details: { path: path })
    def refuse!(result) = raise(Refused, result)

    private_class_method :record, :create_animal, :observation!, :parse, :date, :uuid?, :invalid, :refuse!
  end
end
