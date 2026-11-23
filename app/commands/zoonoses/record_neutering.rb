# Castração (módulo 35b, ADR 0054; contrato §1, §7). Corpo: `animal_id`,
# `performed_on` ("AAAA-MM-DD", padrão hoje; depois de hoje →
# date_out_of_range) e `shelter_stay_id` (opcional, estada do mesmo animal).
# Toda recusa de campo é invalid_request com o path.
#
#   - Quem: só Access.veterinarian? (senão 403 veterinarian_required); o
#     professional_id é o do usuário, congelado (só acréscimo, trigger).
#   - O animal FOR UPDATE (a primeira trava das escritas do canil):
#     transferred ou deceased → 409 animal_not_active; já castrado (ou com
#     castração gravada) → 409 invalid_transition path status (Desvio 4; o
#     índice único idx_neuterings_animal é o cinto).
#   - Marca animals.neutered = true (não volta, trigger), version + 1
#     (`animal.changed`).
#
# `neutering.recorded` só com o id.
module Zoonoses
  module RecordNeutering
    EVENT = "neutering.recorded".freeze
    KEYS = %w[animal_id performed_on shelter_stay_id].freeze
    UNIQUE_INDEX = "idx_neuterings_animal".freeze
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    DATE = /\A\d{4}-\d{2}-\d{2}\z/
    KEY_PATH_MAX = 64

    module_function

    # -> Result.ok(neutering:) | fail(:invalid_request | :date_out_of_range, details: { path: }) |
    #    fail(:invalid_transition, details: { path: "status" }) | fail(:veterinarian_required | :animal_not_active)
    def call(params:, by:, today: Time.zone.today)
      return Result.fail(:veterinarian_required) unless Access.veterinarian?(by)

      params = params.to_h.stringify_keys
      attrs = parse(params, today)
      return attrs if attrs.is_a?(Result)

      Neutering.transaction(requires_new: true) { record(attrs, by) }
    rescue ActiveRecord::RecordNotUnique => e
      raise unless e.message.include?(UNIQUE_INDEX)

      Result.fail(:invalid_transition, details: { path: "status" })
    end

    def record(attrs, by)
      animal = Animal.lock.find_by(id: attrs[:animal_id])
      return invalid("animal_id") unless animal
      return Result.fail(:animal_not_active) unless SaveAnimal::TRANSITIONS.key?(animal.status)
      return Result.fail(:invalid_transition, details: { path: "status" }) if animal.neutered || Neutering.exists?(animal_id: animal.id)
      if attrs[:shelter_stay_id] && !ShelterStay.exists?(id: attrs[:shelter_stay_id], animal_id: animal.id)
        return invalid("shelter_stay_id")
      end

      neutering = Neutering.create!(animal: animal, professional_id: by.professional.id, performed_on: attrs[:performed_on],
                                    shelter_stay_id: attrs[:shelter_stay_id])
      animal.update!(neutered: true, version: animal.version + 1)
      DomainEvents.publish("animal.changed", animal_id: animal.id)
      DomainEvents.publish(EVENT, neutering_id: neutering.id)
      Result.ok(neutering: neutering)
    end

    # Forma do corpo. -> { atributo => valor } | Result de recusa (só a primeira).
    def parse(params, today)
      unknown = params.keys.find { |key| !KEYS.include?(key) }
      return invalid(unknown.to_s[0, KEY_PATH_MAX]) if unknown
      return invalid("animal_id") unless uuid?(params["animal_id"])
      return invalid("shelter_stay_id") if params.key?("shelter_stay_id") && !uuid?(params["shelter_stay_id"])

      performed_on = params.key?("performed_on") ? date(params["performed_on"]) : today
      return invalid("performed_on") unless performed_on
      return Result.fail(:date_out_of_range, details: { path: "performed_on" }) if performed_on > today

      { animal_id: params["animal_id"].downcase, shelter_stay_id: params["shelter_stay_id"]&.downcase, performed_on: performed_on }
    end

    def date(value)
      value.is_a?(String) && value.match?(DATE) ? Date.strptime(value, "%Y-%m-%d") : nil
    rescue Date::Error
      nil
    end

    def uuid?(value) = value.is_a?(String) && value.match?(UUID)
    def invalid(path) = Result.fail(:invalid_request, details: { path: path })

    private_class_method :record, :parse, :date, :uuid?, :invalid
  end
end
