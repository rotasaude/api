# Saída do canil ou gatil (módulo 35b, ADR 0054; contrato §1, §7, Q31). Corpo:
# `exit_kind` (Catalog::EXIT_KINDS), `exited_on` (opcional, "AAAA-MM-DD",
# padrão hoje; entre a entrada e hoje → senão date_out_of_range),
# `adopter_patient_id` (só e sempre com adopted) e o obrigatório
# `expected_version` (ausente → expected_version_required; diferente → 409
# stay_changed). Toda recusa de campo é invalid_request com o path.
#
#   - Quem: team? (senão missing_role).
#   - Travas na ordem das quatro escritas do canil: o animal FOR UPDATE, a
#     estada FOR UPDATE (relida: versão, já fechada → 409 invalid_transition
#     path status) e, na morte, a coleira (Zoonoses::AnimalDeath).
#   - returned: o animal precisa de tutor (senão path exit_kind).
#   - adopted: o adotante (Patient não fundido, vindo do POST
#     /zoonoses/person_lookup, Q25) passa a ser o tutor, community false,
#     version + 1 (`animal.changed`); fica na estada.
#   - death: o animal a deceased no dia da saída e a coleira ativa sai com
#     death (Zoonoses::AnimalDeath).
#   - euthanasia: exige a eutanásia do animal já gravada (senão path
#     exit_kind); o animal já está deceased (Zoonoses::RecordEuthanasia).
#   - Fora a euthanasia, o animal precisa estar active ou missing (Q31: a
#     saída death o exige; as outras também, porque transferred e deceased não
#     se editam) → senão 409 animal_not_active.
#
# `shelter_stay.closed` só com o id: o adotante nunca em evento nem em
# Result.details.
module Zoonoses
  module ExitShelter
    EVENT = "shelter_stay.closed".freeze
    KEYS = %w[exit_kind exited_on adopter_patient_id expected_version].freeze
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    DATE = /\A\d{4}-\d{2}-\d{2}\z/
    KEY_PATH_MAX = 64

    module_function

    # -> Result.ok(stay:) | fail(:invalid_request | :date_out_of_range, details: { path: }) |
    #    fail(:expected_version_required, details: { path: "expected_version" }) | fail(:invalid_transition, details: { path: "status" }) |
    #    fail(:missing_role | :stay_changed | :animal_not_active)
    def call(stay:, params:, by:, today: Time.zone.today)
      return Result.fail(:missing_role) unless Access.team?(by)

      params = params.to_h.stringify_keys
      attrs = parse(params)
      return attrs if attrs.is_a?(Result)

      ShelterStay.transaction(requires_new: true) { record(stay, attrs, today) }
    end

    def record(stay, attrs, today)
      animal = Animal.lock.find(stay.animal_id)
      locked = ShelterStay.lock.find(stay.id)
      return Result.fail(:stay_changed) unless locked.version == attrs[:expected_version]
      return Result.fail(:invalid_transition, details: { path: "status" }) unless locked.open?

      exited_on = attrs[:exited_on] || today
      return Result.fail(:date_out_of_range, details: { path: "exited_on" }) unless (locked.entered_on..today).cover?(exited_on)

      kind = attrs[:exit_kind]
      if kind == "euthanasia"
        return invalid("exit_kind") unless Euthanasia.exists?(animal_id: animal.id)
      else
        return Result.fail(:animal_not_active) unless SaveAnimal::TRANSITIONS.key?(animal.status)
      end
      return invalid("exit_kind") if kind == "returned" && animal.tutor_patient_id.nil?
      if kind == "adopted" && !Patient.exists?(id: attrs[:adopter_patient_id], merged_into_id: nil)
        return invalid("adopter_patient_id")
      end

      locked.update!(exit_kind: kind, exited_on: exited_on, adopter_patient_id: attrs[:adopter_patient_id], version: locked.version + 1)
      case kind
      when "adopted" then adopt!(animal, attrs[:adopter_patient_id])
      when "death" then AnimalDeath.apply!(animal: animal, on: exited_on)
      end
      DomainEvents.publish(EVENT, shelter_stay_id: locked.id)
      Result.ok(stay: locked)
    end

    def adopt!(animal, adopter_id)
      animal.update!(tutor_patient_id: adopter_id, community: false, version: animal.version + 1)
      DomainEvents.publish("animal.changed", animal_id: animal.id)
    end

    # Forma do corpo. -> { atributo => valor } | Result de recusa (só a primeira).
    def parse(params)
      unknown = params.keys.find { |key| !KEYS.include?(key) }
      return invalid(unknown.to_s[0, KEY_PATH_MAX]) if unknown

      kind = params["exit_kind"]
      return invalid("exit_kind") unless Catalog::EXIT_KINDS.include?(kind)

      adopter = params["adopter_patient_id"]
      if kind == "adopted" ? !(adopter.is_a?(String) && adopter.match?(UUID)) : params.key?("adopter_patient_id")
        return invalid("adopter_patient_id")
      end

      attrs = { exit_kind: kind, adopter_patient_id: (adopter.downcase if kind == "adopted") }
      if params.key?("exited_on")
        attrs[:exited_on] = date(params["exited_on"])
        return invalid("exited_on") unless attrs[:exited_on]
      end
      return Result.fail(:expected_version_required, details: { path: "expected_version" }) unless params.key?("expected_version")

      version = params["expected_version"]
      return invalid("expected_version") unless version.is_a?(Integer) && version.positive?

      attrs.merge(expected_version: version)
    end

    def date(value)
      value.is_a?(String) && value.match?(DATE) ? Date.strptime(value, "%Y-%m-%d") : nil
    rescue Date::Error
      nil
    end

    def invalid(path) = Result.fail(:invalid_request, details: { path: path })

    private_class_method :record, :adopt!, :parse, :date, :invalid
  end
end
