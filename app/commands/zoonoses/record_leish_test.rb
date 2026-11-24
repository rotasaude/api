# Coleta e sorologia canina da leishmaniose (módulo 35b, ADR 0054; contrato
# §6, §11, §12, Q20, Q21). Toda recusa de campo é invalid_request com o path;
# texto longo é recusado, nunca cortado; nada do animal nem do tutor em
# Result.details, só o path.
#
#   - Coleta (`test` nil). Corpo: `leish_survey_id` (opcional: fora de
#     inquérito, avulsa), `animal_id`, `collected_on` ("AAAA-MM-DD"),
#     `dpp_result` com `dpp_on` (sempre juntos) e, só pelo dashboard,
#     `elisa_result` com `elisa_on` e `elisa_request` (1–30, o número do GAL);
#     pelo app (origin "field", Task 17), também `client_uuid` e nada de ELISA.
#       - Quem: pelo dashboard, team? (senão missing_role); pelo app, só o ACE
#         no escopo da visita do domicílio do animal (Access.collector?): fora
#         do escopo → out_of_scope; o ACS (ou outro CBO) no escopo →
#         cbo_not_allowed; e, com inquérito, o domicílio nos quarteirões dele
#         (household_not_in_survey path leish_survey_id, Q20).
#       - Inquérito inexistente → path leish_survey_id; fora de open →
#         survey_not_open path leish_survey_id.
#       - Animal: inexistente → path animal_id; não cão → animal_not_dog path
#         animal_id; fora de active (missing também) → 409 animal_not_active.
#       - Datas (Q20): collected_on entre o início do inquérito (avulsa: hoje −
#         30) e hoje; dpp_on e elisa_on entre a coleta e hoje → senão
#         date_out_of_range com o path.
#       - A etiqueta é do api (Zoonoses::Label, na mesma transação).
#   - Correção (`test`, só pelo dashboard, team?): `expected_version` (ausente
#     → expected_version_required; divergente → 409 test_changed) e ao menos
#     um de dpp_result, dpp_on, elisa_result, elisa_on, elisa_request (nil
#     apaga). O teste com desfecho não muda de resultado (409
#     invalid_transition path status).
#   - Sempre, sobre o estado final: ELISA (qualquer campo dele) só com DPP
#     reactive → elisa_without_reactive_dpp com o path do campo; resultado e
#     data juntos (path da data ausente, ou do resultado).
#
# Com resultado lançado, result_by_user é quem lançou. `leish_test.recorded`
# só com o id, na coleta e na correção.
module Zoonoses
  module RecordLeishTest
    EVENT = "leish_test.recorded".freeze
    ORIGINS = %w[dashboard field].freeze
    RESULT_KEYS = %w[dpp_result dpp_on elisa_request elisa_result elisa_on].freeze
    ELISA_KEYS = %w[elisa_result elisa_on elisa_request].freeze
    DASHBOARD_KEYS = (%w[leish_survey_id animal_id collected_on] + RESULT_KEYS).freeze
    FIELD_KEYS = %w[leish_survey_id animal_id collected_on dpp_result dpp_on client_uuid].freeze
    REQUIRED = %w[animal_id collected_on].freeze
    LOOSE_BACKDATE_DAYS = 30
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    DATE = /\A\d{4}-\d{2}-\d{2}\z/
    KEY_PATH_MAX = 64
    INVALID = Object.new.freeze

    module_function

    # -> Result.ok(test:) | fail(:invalid_request | :date_out_of_range | :survey_not_open | :animal_not_dog
    #    | :elisa_without_reactive_dpp | :household_not_in_survey, details: { path: })
    #    | fail(:missing_role | :out_of_scope | :cbo_not_allowed | :animal_not_active | :test_changed)
    #    | fail(:expected_version_required, details: { path: "expected_version" })
    def call(params:, by:, test: nil, origin: "dashboard", today: Time.zone.today)
      raise ArgumentError, "origin: #{origin}" unless ORIGINS.include?(origin)
      raise ArgumentError, "a correção é só pelo dashboard" if test && origin != "dashboard"
      return Result.fail(:missing_role) if origin == "dashboard" && !Access.team?(by)

      params = params.to_h.stringify_keys
      test ? correct(test, params, by, today) : collect(params, by, origin, today)
    end

    def collect(params, by, origin, today)
      attrs = parse(params, origin == "field" ? FIELD_KEYS : DASHBOARD_KEYS)
      return attrs if attrs.is_a?(Result)

      missing = REQUIRED.find { |key| attrs[key.to_sym].nil? }
      return invalid(missing) if missing

      failure = shape(attrs)
      return failure if failure

      LeishTest.transaction(requires_new: true) do
        survey = nil
        if attrs[:leish_survey_id]
          survey = LeishSurvey.lock("FOR SHARE").find_by(id: attrs[:leish_survey_id])
          next invalid("leish_survey_id") unless survey
          next Result.fail(:survey_not_open, details: { path: "leish_survey_id" }) unless survey.stage == "open"
        end
        animal = Animal.lock("FOR SHARE").find_by(id: attrs[:animal_id])
        next invalid("animal_id") unless animal
        next Result.fail(:animal_not_dog, details: { path: "animal_id" }) unless animal.species == "dog"
        next Result.fail(:animal_not_active) unless animal.active?

        failure = origin == "field" ? field_scope(animal, by, survey) : nil
        next failure if failure

        earliest = survey ? survey.starts_on : today - LOOSE_BACKDATE_DAYS
        next out_of_range("collected_on") unless (earliest..today).cover?(attrs[:collected_on])

        failure = result_dates(attrs, attrs[:collected_on], today)
        next failure if failure

        test = LeishTest.create!(attrs.merge(label: Label.next!(survey: survey, year: attrs[:collected_on].year),
                                             result_by_user: result?(attrs) ? by : nil))
        recorded!(test)
      end
    end

    def correct(test, params, by, today)
      return Result.fail(:expected_version_required, details: { path: "expected_version" }) unless params.key?("expected_version")

      expected = params.delete("expected_version")
      return invalid("expected_version") unless expected.is_a?(Integer) && expected.positive?

      attrs = parse(params, RESULT_KEYS)
      return attrs if attrs.is_a?(Result)
      return invalid(nil) if attrs.empty?

      LeishTest.transaction(requires_new: true) do
        locked = LeishTest.lock.find(test.id)
        next Result.fail(:test_changed) unless locked.version == expected

        state = RESULT_KEYS.to_h { |key| [ key.to_sym, locked.public_send(key) ] }.merge(attrs)
        next Result.fail(:invalid_transition, details: { path: "status" }) if decided_change?(locked, state)

        failure = shape(state) || result_dates(attrs.compact, locked.collected_on, today)
        next failure if failure

        locked.update!(attrs.merge(version: locked.version + 1, result_by_user: by))
        recorded!(locked)
      end
    end

    # Pelo app: o ACE no escopo do domicílio do animal e, com inquérito, o
    # domicílio nos quarteirões dele. -> nil | Result de recusa.
    def field_scope(animal, by, survey)
      household = animal.household_id && Household.includes(micro_area: :team).find_by(id: animal.household_id)
      unless household && Access.collector?(by, household)
        return Result.fail(household && Access.field_agent?(by, household) ? :cbo_not_allowed : :out_of_scope)
      end
      return nil if survey.nil? || SurveyArea.includes_household?(survey.city_block_ids, household.id)

      Result.fail(:household_not_in_survey, details: { path: "leish_survey_id" })
    end

    # O estado final dos resultados. -> nil | Result de recusa.
    def shape(state)
      return invalid("dpp_on") if state[:dpp_result] && state[:dpp_on].nil?
      return invalid("dpp_result") if state[:dpp_on] && state[:dpp_result].nil?

      elisa = ELISA_KEYS.find { |key| !state[key.to_sym].nil? }
      return Result.fail(:elisa_without_reactive_dpp, details: { path: elisa }) if elisa && state[:dpp_result] != "reactive"
      return invalid("elisa_on") if state[:elisa_result] && state[:elisa_on].nil?
      return invalid("elisa_result") if state[:elisa_on] && state[:elisa_result].nil?

      nil
    end

    def result_dates(attrs, collected_on, today)
      %i[dpp_on elisa_on].each do |key|
        return out_of_range(key.to_s) if attrs[key] && !(collected_on..today).cover?(attrs[key])
      end
      nil
    end

    # O desfecho foi decidido sobre o resultado reagente: com desfecho, os
    # resultados não mudam.
    def decided_change?(locked, state)
      return false unless LeishDogOutcome.exists?(leish_test_id: locked.id)

      state[:dpp_result] != locked.dpp_result || state[:elisa_result] != locked.elisa_result
    end

    def result?(attrs) = !attrs[:dpp_result].nil? || !attrs[:elisa_result].nil?

    def recorded!(test)
      DomainEvents.publish(EVENT, leish_test_id: test.id)
      Result.ok(test: test)
    end

    # Forma do corpo. -> { atributo => valor } | Result de recusa (só a primeira).
    def parse(params, allowed)
      unknown = params.keys.find { |key| !allowed.include?(key) }
      return invalid(unknown.to_s[0, KEY_PATH_MAX]) if unknown

      params.each_with_object({}) do |(key, value), attrs|
        parsed = value.nil? ? nil : parse_value(key, value)
        return invalid(key) if parsed.equal?(INVALID)

        attrs[key.to_sym] = parsed
      end
    end

    def parse_value(key, value)
      case key
      when "leish_survey_id", "animal_id", "client_uuid" then value.is_a?(String) && value.match?(UUID) ? value.downcase : INVALID
      when "collected_on", "dpp_on", "elisa_on" then date(value)
      when "dpp_result" then Catalog::DPP_RESULTS.include?(value) ? value : INVALID
      when "elisa_result" then Catalog::ELISA_RESULTS.include?(value) ? value : INVALID
      when "elisa_request"
        clean = value.is_a?(String) ? value.strip : nil
        clean && Catalog::ELISA_REQUEST.cover?(clean.length) ? clean : INVALID
      end
    end

    def date(value)
      return INVALID unless value.is_a?(String) && value.match?(DATE)

      Date.strptime(value, "%Y-%m-%d")
    rescue Date::Error
      INVALID
    end

    def out_of_range(path) = Result.fail(:date_out_of_range, details: { path: path })

    def invalid(path) = Result.fail(:invalid_request, details: { path: path })

    private_class_method :collect, :correct, :field_scope, :shape, :result_dates, :decided_change?, :result?, :recorded!, :parse,
                         :parse_value, :date, :out_of_range, :invalid
  end
end
