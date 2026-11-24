# Desfecho do cão reagente da leishmaniose (módulo 35b, ADR 0054; contrato §6,
# §10, Q18). Só team? (senão missing_role). Corpo: `leish_test_id`,
# `decision` (tutor_treatment | euthanasia | refused), `decided_on`
# ("AAAA-MM-DD", entre a coleta e hoje, senão date_out_of_range), `note`
# (10–500, opcional, cifrada), `euthanasia_id` (só com euthanasia) e
# `animal_id` (opcional; se vier, o do teste). Toda recusa de campo é
# invalid_request com o path; texto longo é recusado, nunca cortado.
#
#   - O teste reagente nos dois (DPP e ELISA reactive), senão path
#     leish_test_id. Um desfecho por teste (sob a trava do teste e o índice
#     único): o segundo → 409 invalid_transition path status.
#   - euthanasia exige a eutanásia já registrada do animal do teste (Q18; path
#     euthanasia_id), que não serve a outro desfecho.
#   - tutor_treatment e refused exigem tutor no animal (path decision).
#
# `leish_dog_outcome.recorded` só com o id.
module Zoonoses
  module RecordLeishOutcome
    EVENT = "leish_dog_outcome.recorded".freeze
    KEYS = %w[leish_test_id animal_id decision decided_on note euthanasia_id].freeze
    REQUIRED = %w[leish_test_id decision decided_on].freeze
    NOTE = (10..500)
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    DATE = /\A\d{4}-\d{2}-\d{2}\z/
    KEY_PATH_MAX = 64
    TEST_INDEX = "idx_leish_dog_outcomes_test".freeze
    EUTHANASIA_INDEX = "idx_leish_dog_outcomes_euthanasia".freeze
    INVALID = Object.new.freeze

    module_function

    # -> Result.ok(outcome:) | fail(:missing_role) | fail(:invalid_request | :date_out_of_range, details: { path: })
    #    | fail(:invalid_transition, details: { path: "status" })
    def call(params:, by:, today: Time.zone.today)
      return Result.fail(:missing_role) unless Access.team?(by)

      attrs = parse(params.to_h.stringify_keys)
      return attrs if attrs.is_a?(Result)
      return invalid("euthanasia_id") if attrs[:euthanasia_id] && attrs[:decision] != "euthanasia"

      record(attrs, today)
    rescue ActiveRecord::RecordNotUnique => e
      return Result.fail(:invalid_transition, details: { path: "status" }) if e.message.include?(TEST_INDEX)
      return invalid("euthanasia_id") if e.message.include?(EUTHANASIA_INDEX)

      raise
    end

    def record(attrs, today)
      LeishDogOutcome.transaction(requires_new: true) do
        test = LeishTest.lock.find_by(id: attrs[:leish_test_id])
        next invalid("leish_test_id") unless test && test.dpp_result == "reactive" && test.elisa_result == "reactive"
        next invalid("animal_id") if attrs[:animal_id] && attrs[:animal_id] != test.animal_id
        next Result.fail(:invalid_transition, details: { path: "status" }) if LeishDogOutcome.exists?(leish_test_id: test.id)
        next Result.fail(:date_out_of_range, details: { path: "decided_on" }) unless (test.collected_on..today).cover?(attrs[:decided_on])

        failure = decision!(attrs, Animal.find(test.animal_id))
        next failure if failure

        outcome = LeishDogOutcome.create!(attrs.except(:animal_id).merge(animal_id: test.animal_id))
        DomainEvents.publish(EVENT, leish_dog_outcome_id: outcome.id)
        Result.ok(outcome: outcome)
      end
    end

    # -> nil | Result de recusa.
    def decision!(attrs, animal)
      return (animal.tutor_patient_id ? nil : invalid("decision")) unless attrs[:decision] == "euthanasia"
      return invalid("euthanasia_id") unless attrs[:euthanasia_id]
      return invalid("euthanasia_id") unless Euthanasia.exists?(id: attrs[:euthanasia_id], animal_id: animal.id)
      return invalid("euthanasia_id") if LeishDogOutcome.exists?(euthanasia_id: attrs[:euthanasia_id])

      nil
    end

    # -> { atributo => valor } | Result de recusa (só a primeira).
    def parse(params)
      unknown = params.keys.find { |key| !KEYS.include?(key) }
      return invalid(unknown.to_s[0, KEY_PATH_MAX]) if unknown

      missing = REQUIRED.find { |key| params[key].nil? }
      return invalid(missing) if missing

      params.each_with_object({}) do |(key, value), attrs|
        parsed = value.nil? ? nil : parse_value(key, value)
        return invalid(key) if parsed.equal?(INVALID)

        attrs[key.to_sym] = parsed
      end
    end

    def parse_value(key, value)
      case key
      when "leish_test_id", "animal_id", "euthanasia_id" then value.is_a?(String) && value.match?(UUID) ? value.downcase : INVALID
      when "decision" then Catalog::LEISH_DECISIONS.include?(value) ? value : INVALID
      when "decided_on" then date(value)
      when "note"
        clean = value.is_a?(String) ? value.strip : nil
        clean && NOTE.cover?(clean.length) ? clean : INVALID
      end
    end

    def date(value)
      return INVALID unless value.is_a?(String) && value.match?(DATE)

      Date.strptime(value, "%Y-%m-%d")
    rescue Date::Error
      INVALID
    end

    def invalid(path) = Result.fail(:invalid_request, details: { path: path })

    private_class_method :record, :decision!, :parse, :parse_value, :date, :invalid
  end
end
