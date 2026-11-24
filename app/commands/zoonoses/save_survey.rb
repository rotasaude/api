# Inquérito de leishmaniose visceral canina (módulo 35b, ADR 0054; contrato
# §6, §10, Q8, Q18, Q28, Q32; plano, Desvio 4). Só a coordenação
# (coordinator?, senão missing_role).
#
#   - `call` cria ou edita. Corpo: `name` (1–80), `kind` (sample | census |
#     focus), `neighborhood_id`, `city_block_ids` (não vazio, sem repetição,
#     quarteirões ativos do 35a — Q8: sem depender do vector_control),
#     `dog_population` (inteiro > 0, informado), `starts_on`/`ends_on`
#     ("AAAA-MM-DD", fim ≥ início). No foco, `center_city_block_id` no lugar de
#     `city_block_ids` grava os quarteirões da sugestão (SurveyArea, Q28).
#     `target_dogs` é sempre do api (Zoonoses::LeishSample, com os parâmetros
#     vigentes, cuja versão fica em parameters_version); mandá-lo é
#     invalid_request. A edição leva `expected_version` e só vale em draft
#     (sob a trava: fora de draft → 409 invalid_transition path status, depois
#     a versão divergente → 409 survey_changed). Toda recusa de campo é
#     invalid_request com o path; texto longo é recusado, nunca cortado.
#   - `transition` (draft → open, open → closed), com expected_version.
#   - `suggest` (Q28): a sugestão de quarteirões, população e amostra; não
#     grava nada.
#
# Toda escrita sobe a version e publica `leish_survey.changed` só com o id.
module Zoonoses
  module SaveSurvey
    EVENT = "leish_survey.changed".freeze
    KEYS = %w[name kind neighborhood_id city_block_ids center_city_block_id dog_population starts_on ends_on].freeze
    REQUIRED = %w[name kind neighborhood_id dog_population starts_on ends_on].freeze
    SUGGEST_KEYS = %w[kind neighborhood_id center_city_block_id rings].freeze
    NAME = (1..80)
    DOG_POPULATION = (1..10_000_000)
    RINGS = (0..SurveyArea::MAX_FOCUS_RINGS)
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    DATE = /\A\d{4}-\d{2}-\d{2}\z/
    KEY_PATH_MAX = 64
    INVALID = Object.new.freeze

    module_function

    # -> Result.ok(survey:) | fail(:missing_role) | fail(:invalid_request, details: { path: })
    #    | fail(:expected_version_required, details: { path: "expected_version" }) | fail(:survey_changed)
    #    | fail(:invalid_transition, details: { path: "status" })
    def call(params:, by:, survey: nil)
      return Result.fail(:missing_role) unless Access.coordinator?(by)

      params = params.to_h.stringify_keys
      expected = nil
      if survey
        expected = expected_version(params)
        return expected if expected.is_a?(Result)
      end
      values = parse(params, editing: !survey.nil?)
      return values if values.is_a?(Result)

      LeishSurvey.transaction(requires_new: true) do
        locked = survey && LeishSurvey.lock.find(survey.id)
        if locked
          next Result.fail(:invalid_transition, details: { path: "status" }) unless locked.stage == "draft"
          next Result.fail(:survey_changed) unless locked.version == expected
        end
        save(locked, values)
      end
    end

    def transition(survey:, params:, by:, from:, to:)
      return Result.fail(:missing_role) unless Access.coordinator?(by)

      params = params.to_h.stringify_keys
      expected = expected_version(params)
      return expected if expected.is_a?(Result)
      return invalid(params.keys.first.to_s[0, KEY_PATH_MAX]) if params.any?

      LeishSurvey.transaction(requires_new: true) do
        locked = LeishSurvey.lock.find(survey.id)
        next Result.fail(:invalid_transition, details: { path: "status" }) unless locked.stage == from
        next Result.fail(:survey_changed) unless locked.version == expected

        locked.update!(stage: to, version: locked.version + 1)
        changed!(locked)
      end
    end

    # -> Result.ok(suggestion: { city_block_ids:, dog_population_suggested:, target_dogs:, below_focus_min: })
    def suggest(params:, by:)
      return Result.fail(:missing_role) unless Access.coordinator?(by)

      params = params.to_h.stringify_keys
      unknown = params.keys.find { |key| !SUGGEST_KEYS.include?(key) }
      return invalid(unknown.to_s[0, KEY_PATH_MAX]) if unknown
      return invalid("kind") unless Catalog::SURVEY_KINDS.include?(params["kind"])
      return invalid("neighborhood_id") unless uuid?(params["neighborhood_id"]) && Neighborhood.exists?(id: params["neighborhood_id"])

      focus = params["kind"] == "focus"
      center = params["center_city_block_id"]
      return invalid("center_city_block_id") if focus ? !active_block?(center) : params.key?("center_city_block_id")

      rings = params["rings"]
      return invalid("rings") if params.key?("rings") && !(focus && rings.is_a?(Integer) && RINGS.cover?(rings))

      Result.ok(suggestion: SurveyArea.suggestion(kind: params["kind"], neighborhood_id: params["neighborhood_id"], parameters: Parameters.current,
                                                  center_block_id: center, rings: rings))
    end

    def save(locked, values)
      survey = locked || LeishSurvey.new(stage: "draft")
      center = values.delete(:center_city_block_id)
      survey.assign_attributes(values)
      return invalid("ends_on") if survey.ends_on < survey.starts_on

      parameters = Parameters.current
      if center
        return invalid("center_city_block_id") unless survey.kind == "focus"

        survey.city_block_ids = SurveyArea.suggestion(kind: "focus", neighborhood_id: survey.neighborhood_id, parameters: parameters,
                                                      center_block_id: center)[:city_block_ids]
      end
      survey.target_dogs = LeishSample.target(kind: survey.kind, dog_population: survey.dog_population, parameters: parameters)
      survey.parameters_version = parameters.version
      survey.version += 1 if locked
      survey.save!
      changed!(survey)
    end

    def changed!(survey)
      DomainEvents.publish(EVENT, leish_survey_id: survey.id)
      Result.ok(survey: survey)
    end

    # Tira `expected_version` de `params`. -> Integer | Result de recusa.
    def expected_version(params)
      return Result.fail(:expected_version_required, details: { path: "expected_version" }) unless params.key?("expected_version")

      expected = params.delete("expected_version")
      expected.is_a?(Integer) && expected.positive? ? expected : invalid("expected_version")
    end

    # -> { atributo => valor } | Result de recusa (só a primeira).
    def parse(params, editing:)
      unknown = params.keys.find { |key| !KEYS.include?(key) }
      return invalid(unknown.to_s[0, KEY_PATH_MAX]) if unknown
      return invalid(nil) if editing && params.empty?

      unless editing
        missing = REQUIRED.find { |key| !params.key?(key) }
        return invalid(missing) if missing
        return invalid("city_block_ids") unless params.key?("city_block_ids") || params.key?("center_city_block_id")
      end
      return invalid("center_city_block_id") if params.key?("city_block_ids") && params.key?("center_city_block_id")

      params.each_with_object({}) do |(key, value), values|
        parsed = parse_value(key, value)
        return invalid(key) if parsed.equal?(INVALID)

        values[key.to_sym] = parsed
      end
    end

    def parse_value(key, value)
      case key
      when "name"
        clean = value.is_a?(String) ? value.strip : nil
        clean && NAME.cover?(clean.length) ? clean : INVALID
      when "kind" then Catalog::SURVEY_KINDS.include?(value) ? value : INVALID
      when "neighborhood_id" then uuid?(value) && Neighborhood.exists?(id: value) ? value.downcase : INVALID
      when "city_block_ids" then blocks(value)
      when "center_city_block_id" then active_block?(value) ? value.downcase : INVALID
      when "dog_population" then value.is_a?(Integer) && DOG_POPULATION.cover?(value) ? value : INVALID
      when "starts_on", "ends_on" then date(value)
      end
    end

    # Não vazio, sem repetição, todos ativos. -> [uuid] | INVALID
    def blocks(value)
      return INVALID unless value.is_a?(Array) && value.any? && value.all? { |id| uuid?(id) }

      ids = value.map(&:downcase)
      return INVALID unless ids.uniq.size == ids.size && CityBlock.active_blocks.where(id: ids).count == ids.size

      ids
    end

    def active_block?(value) = uuid?(value) && CityBlock.active_blocks.exists?(id: value)

    def uuid?(value) = value.is_a?(String) && value.match?(UUID)

    def date(value)
      return INVALID unless value.is_a?(String) && value.match?(DATE)

      Date.strptime(value, "%Y-%m-%d")
    rescue Date::Error
      INVALID
    end

    def invalid(path) = Result.fail(:invalid_request, details: { path: path })

    private_class_method :save, :changed!, :expected_version, :parse, :parse_value, :blocks, :active_block?, :uuid?, :date, :invalid
  end
end
