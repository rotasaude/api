# Campanha de vacinação antirrábica (módulo 35b, ADR 0054; contrato §3, §9,
# §10; plano, Desvio 4). Só a coordenação (coordinator?, senão missing_role).
#
#   - `call` cria ou edita. Corpo: `name` (1–80), `starts_on`/`ends_on`
#     ("AAAA-MM-DD", fim ≥ início, senão path ends_on), `year` (opcional; o
#     ano de starts_on), `goal_dogs`/`goal_cats` (inteiros ≥ 0). Meta ausente
#     na criação → round(estimativa × rabies_coverage_target) com a estimativa
#     de população dos parâmetros (§9); sem estimativa → invalid_request path
#     goal_dogs (ou goal_cats). A edição leva `expected_version` (ausente →
#     expected_version_required; fora de inteiro ≥ 1 → invalid_request) e ao
#     menos uma chave; sob a trava (FOR UPDATE), fora de planned → 409
#     invalid_transition path status, depois version divergente → 409
#     campaign_changed. Toda recusa de campo é invalid_request com o path;
#     texto longo é recusado, nunca cortado.
#   - `open` (planned → open): outra campanha open → 409
#     campaign_already_open (também pela corrida, no índice único
#     idx_rabies_campaigns_open). `close` (open → closed). Fora da etapa →
#     invalid_transition path status. Nunca volta (trigger).
#
# Toda escrita sobe a version e publica `rabies_campaign.changed` só com o id.
module Zoonoses
  module SaveCampaign
    EVENT = "rabies_campaign.changed".freeze
    KEYS = %w[name year starts_on ends_on goal_dogs goal_cats].freeze
    REQUIRED = %w[name starts_on ends_on].freeze
    GOALS = { "goal_dogs" => "dog_population_estimate", "goal_cats" => "cat_population_estimate" }.freeze
    DATE = /\A\d{4}-\d{2}-\d{2}\z/
    YEARS = (2000..2100)
    KEY_PATH_MAX = 64
    INVALID = Object.new.freeze

    module_function

    # -> Result.ok(campaign:) | fail(:missing_role) | fail(:invalid_request, details: { path: })
    #    | fail(:expected_version_required, details: { path: "expected_version" }) | fail(:campaign_changed)
    #    | fail(:invalid_transition, details: { path: "status" })
    def call(params:, by:, campaign: nil, parameters: nil)
      return Result.fail(:missing_role) unless Access.coordinator?(by)

      params = params.to_h.stringify_keys
      expected = nil
      if campaign
        return Result.fail(:expected_version_required, details: { path: "expected_version" }) unless params.key?("expected_version")

        expected = params.delete("expected_version")
        return invalid("expected_version") unless expected.is_a?(Integer) && expected.positive?
      end
      values = parse(params, editing: !campaign.nil?)
      return values if values.is_a?(Result)

      campaign ? update(campaign, values, expected) : create(values, parameters || Parameters.current)
    end

    def open(campaign:, by:)
      transition(campaign, by, from: "planned", to: "open")
    rescue ActiveRecord::RecordNotUnique => e
      raise unless e.message.include?("idx_rabies_campaigns_open")

      Result.fail(:campaign_already_open)
    end

    def close(campaign:, by:) = transition(campaign, by, from: "open", to: "closed")

    def create(values, parameters)
      GOALS.each do |goal, estimate_key|
        next if values.key?(goal.to_sym)

        estimate = parameters.values[estimate_key]
        return invalid(goal) unless estimate.is_a?(Integer)

        values[goal.to_sym] = (estimate * parameters.values.fetch("rabies_coverage_target").to_d).round.to_i
      end
      return invalid("ends_on") if values[:ends_on] < values[:starts_on]

      RabiesCampaign.transaction(requires_new: true) do
        campaign = RabiesCampaign.create!(values.reverse_merge(year: values[:starts_on].year, stage: "planned"))
        changed!(campaign)
      end
    end

    def update(campaign, values, expected)
      RabiesCampaign.transaction(requires_new: true) do
        locked = RabiesCampaign.lock.find(campaign.id)
        next Result.fail(:invalid_transition, details: { path: "status" }) unless locked.stage == "planned"
        next Result.fail(:campaign_changed) unless locked.version == expected

        locked.assign_attributes(values)
        next invalid("ends_on") if locked.ends_on < locked.starts_on

        locked.version += 1
        locked.save!
        changed!(locked)
      end
    end

    def transition(campaign, by, from:, to:)
      return Result.fail(:missing_role) unless Access.coordinator?(by)

      RabiesCampaign.transaction(requires_new: true) do
        locked = RabiesCampaign.lock.find(campaign.id)
        next Result.fail(:invalid_transition, details: { path: "status" }) unless locked.stage == from
        next Result.fail(:campaign_already_open) if to == "open" && RabiesCampaign.open_campaigns.where.not(id: locked.id).exists?

        locked.update!(stage: to, version: locked.version + 1)
        changed!(locked)
      end
    end

    def changed!(campaign)
      DomainEvents.publish(EVENT, rabies_campaign_id: campaign.id)
      Result.ok(campaign: campaign)
    end

    # -> { atributo => valor } | Result de recusa (só a primeira).
    def parse(params, editing:)
      unknown = params.keys.find { |key| !KEYS.include?(key) }
      return invalid(unknown.to_s[0, KEY_PATH_MAX]) if unknown
      return invalid(nil) if editing && params.empty?

      missing = REQUIRED.find { |key| !params.key?(key) } unless editing
      return invalid(missing) if missing

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
        clean && Catalog::CAMPAIGN_NAME.cover?(clean.length) ? clean : INVALID
      when "starts_on", "ends_on" then date(value)
      when "year" then value.is_a?(Integer) && YEARS.cover?(value) ? value : INVALID
      when "goal_dogs", "goal_cats" then value.is_a?(Integer) && value >= 0 ? value : INVALID
      end
    end

    def date(value)
      return INVALID unless value.is_a?(String) && value.match?(DATE)

      Date.strptime(value, "%Y-%m-%d")
    rescue Date::Error
      INVALID
    end

    def invalid(path) = Result.fail(:invalid_request, details: { path: path })

    private_class_method :create, :update, :transition, :changed!, :parse, :parse_value, :date, :invalid
  end
end
