# Colocação da coleira de deltametrina no cão (módulo 35b, ADR 0054; contrato
# §6, §3, Q20, Q23). Corpo: `animal_id`, `vector_product_id`, `placed_on`
# ("AAAA-MM-DD", padrão hoje; depois de hoje → date_out_of_range) e, só pelo
# app, `client_uuid`. Toda recusa de campo é invalid_request com o path.
#
#   - Quem: pelo dashboard, team? (senão missing_role); pelo app (origin
#     "field"), o gate de campo (`zoonoses_field:`, lido FORA da transação,
#     senão feature_disabled) e o agente no escopo do domicílio do animal
#     (Access.field_agent?, senão out_of_scope; animal sem domicílio → path
#     animal_id).
#   - Animal cão (senão animal_not_dog) e active (senão animal_not_active);
#     produto ativo com a finalidade collar (senão path vector_product_id).
#   - due_on = placed_on + collar_months (Parameters vigente).
#
# Ordem de trava (a da AnimalDeath, para não travar em ciclo): o animal FOR
# UPDATE → a coleira ativa. A anterior sai com `replaced` em placed_on (nunca
# antes da colocação dela) na mesma transação (`collar.removed`); a baixa de
# 1 un (Zoonoses::ApplyStock, falta com occurred_on = placed_on) nunca
# recusa; `collar.placed` só com o id.
module Zoonoses
  module PlaceCollar
    EVENT = "collar.placed".freeze
    STOCK_KIND = "collar_placement".freeze
    COLLAR_USE = "collar".freeze
    REPLACED = "replaced".freeze
    KEYS = %w[animal_id vector_product_id placed_on].freeze
    FIELD_KEYS = (KEYS + %w[client_uuid]).freeze
    ORIGINS = %w[dashboard field].freeze
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    DATE = /\A\d{4}-\d{2}-\d{2}\z/
    KEY_PATH_MAX = 64

    module_function

    # -> Result.ok(collar:) | fail(:invalid_request | :date_out_of_range, details: { path: })
    #    | fail(:missing_role | :out_of_scope | :feature_disabled | :animal_not_dog | :animal_not_active)
    def call(params:, by:, origin: "dashboard", zoonoses_field: false, today: Time.zone.today)
      raise ArgumentError, "origin: #{origin}" unless ORIGINS.include?(origin)
      return Result.fail(:missing_role) if origin == "dashboard" && !Access.team?(by)
      return Result.fail(:feature_disabled) if origin == "field" && !zoonoses_field

      attrs = parse(params.to_h.stringify_keys, origin, today)
      return attrs if attrs.is_a?(Result)

      Collar.transaction(requires_new: true) { place(attrs, by, origin, today) }
    end

    def place(attrs, by, origin, today)
      animal = Animal.lock.find_by(id: attrs[:animal_id])
      return invalid("animal_id") unless animal
      return Result.fail(:animal_not_dog) unless animal.species == "dog"
      return Result.fail(:animal_not_active) unless animal.status == "active"
      return invalid("vector_product_id") unless VectorProduct.where(active: true).where("? = ANY(uses)", COLLAR_USE)
                                                              .exists?(id: attrs[:vector_product_id])
      if origin == "field"
        household = animal.household_id && Household.includes(micro_area: :team).find_by(id: animal.household_id)
        return invalid("animal_id") unless household
        return Result.fail(:out_of_scope) unless Access.field_agent?(by, household)
      end

      previous = Collar.active.lock.find_by(animal_id: animal.id)
      if previous
        previous.update!(removed_on: [ attrs[:placed_on], previous.placed_on ].max, removal_reason: REPLACED)
        DomainEvents.publish("collar.removed", collar_id: previous.id)
      end

      months = Parameters.current.values.fetch("collar_months")
      collar = Collar.create!(attrs.merge(due_on: attrs[:placed_on] >> months))
      ApplyStock.call(document: collar, product_id: collar.vector_product_id, kind: STOCK_KIND, by: by, today: today)
      DomainEvents.publish(EVENT, collar_id: collar.id)
      Result.ok(collar: collar)
    end

    # Forma do corpo. -> { atributo => valor } | Result de recusa (só a primeira).
    def parse(params, origin, today)
      allowed = origin == "field" ? FIELD_KEYS : KEYS
      unknown = params.keys.find { |key| !allowed.include?(key) }
      return invalid(unknown.to_s[0, KEY_PATH_MAX]) if unknown
      return invalid("animal_id") unless uuid?(params["animal_id"])
      return invalid("vector_product_id") unless uuid?(params["vector_product_id"])
      return invalid("client_uuid") if params["client_uuid"] && !uuid?(params["client_uuid"])

      placed_on = params.key?("placed_on") ? date(params["placed_on"]) : today
      return invalid("placed_on") unless placed_on
      return Result.fail(:date_out_of_range, details: { path: "placed_on" }) if placed_on > today

      { animal_id: params["animal_id"].downcase, vector_product_id: params["vector_product_id"].downcase,
        placed_on: placed_on, client_uuid: params["client_uuid"]&.downcase }.compact
    end

    def date(value)
      value.is_a?(String) && value.match?(DATE) ? Date.strptime(value, "%Y-%m-%d") : nil
    rescue Date::Error
      nil
    end

    def uuid?(value) = value.is_a?(String) && value.match?(UUID)
    def invalid(path) = Result.fail(:invalid_request, details: { path: path })

    private_class_method :place, :parse, :date, :uuid?, :invalid
  end
end
