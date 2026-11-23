# Registro da dose de vacina antirrábica (módulo 35b, ADR 0054; contrato §1,
# §3, Q4, Q19, Q20). Corpo: `modality` (house | fixed_post | routine),
# `campaign_id`, `animal_id`, `species`, `vaccinated_on` ("AAAA-MM-DD"),
# `vector_product_id`, `adverse_event` (bool, obrigatório), `adverse_note`
# (10–500, só com adverse_event), `health_unit_id` (unidade ativa, opcional,
# fora do casa a casa) e, só pelo app, `client_uuid`. Toda recusa de campo é
# invalid_request com o path; texto longo é recusado, nunca cortado.
#
#   - Quem: pelo dashboard, team? (senão missing_role); pelo app (origin
#     "field", Task 17), só `house` e o agente no escopo do domicílio do
#     animal (Access.field_agent?, senão out_of_scope).
#   - house: o gate de campo (`zoonoses_field:`, Gate.field_usable? lido FORA
#     da transação, senão feature_disabled), campanha open, animal com
#     domicílio (o da dose; sem domicílio → path animal_id).
#   - fixed_post: campanha open; animal opcional — sem animal, `species`
#     (dog | cat) obrigatória (Q4: nunca nome de tutor digitado).
#   - routine: sem campanha (path campaign_id), com animal.
#   - Com animal: active (senão 409 animal_not_active; missing também), a
#     espécie da dose é a do animal e só cão ou gato (senão path animal_id;
#     `species` diferente → path species). O banco não confere a espécie: é
#     aqui (Task 3).
#   - Campanha inexistente → path campaign_id; não open → campaign_not_open
#     path campaign_id. Data entre o início da campanha (rotina: hoje − 30) e
#     hoje → senão date_out_of_range path vaccinated_on (Q20).
#   - Vacina: vector_product ativo com a finalidade rabies_vaccine (senão path
#     vector_product_id).
#
# Numa transação: campanha e animal FOR SHARE (a campanha não fecha, o animal
# não sai de active no meio), a dose, a baixa de 1 un (Zoonoses::ApplyStock,
# com o dia da dose na falta) e o lote do movimento na dose (stock_lot_id; nulo
# na falta: o trigger aceita de NULL a valor, uma vez). A segunda dose ativa do
# animal na campanha é barrada pelo índice único parcial (inclusive na
# corrida: a segunda espera a primeira no índice) → already_vaccinated_in_campaign,
# e a dose e a baixa voltam juntas (Review Focus 1; Q19: só o api barra).
# `rabies_vaccination.recorded` só com o id; nada do animal nem do tutor em
# Result.details, só o path.
module Zoonoses
  module RecordVaccination
    EVENT = "rabies_vaccination.recorded".freeze
    STOCK_KIND = "animal_vaccination".freeze
    KEYS = %w[modality campaign_id animal_id species vaccinated_on vector_product_id adverse_event adverse_note health_unit_id].freeze
    FIELD_KEYS = (KEYS + %w[client_uuid]).freeze
    REQUIRED = %w[modality vaccinated_on vector_product_id adverse_event].freeze
    ORIGINS = %w[dashboard field].freeze
    VACCINE_USE = "rabies_vaccine".freeze
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    DATE = /\A\d{4}-\d{2}-\d{2}\z/
    KEY_PATH_MAX = 64
    SECOND_DOSE_INDEX = "idx_rabies_vaccinations_animal_campaign".freeze
    INVALID = Object.new.freeze

    module_function

    # -> Result.ok(vaccination:) | fail(:invalid_request | :date_out_of_range | :campaign_not_open, details: { path: })
    #    | fail(:missing_role | :out_of_scope | :feature_disabled | :animal_not_active | :already_vaccinated_in_campaign)
    def call(params:, by:, origin: "dashboard", zoonoses_field: false, today: Time.zone.today)
      raise ArgumentError, "origin: #{origin}" unless ORIGINS.include?(origin)
      return Result.fail(:missing_role) if origin == "dashboard" && !Access.team?(by)

      params = params.to_h.stringify_keys
      attrs = parse(params, origin)
      return attrs if attrs.is_a?(Result)
      return Result.fail(:feature_disabled) if attrs[:modality] == "house" && !zoonoses_field

      record(attrs, by, origin, today)
    rescue ActiveRecord::RecordNotUnique => e
      raise unless e.message.include?(SECOND_DOSE_INDEX)

      Result.fail(:already_vaccinated_in_campaign)
    end

    def record(attrs, by, origin, today)
      RabiesVaccination.transaction(requires_new: true) do
        campaign = nil
        if attrs[:campaign_id]
          campaign = RabiesCampaign.lock("FOR SHARE").find_by(id: attrs[:campaign_id])
          next invalid("campaign_id") unless campaign
          next Result.fail(:campaign_not_open, details: { path: "campaign_id" }) unless campaign.stage == "open"
        end
        earliest = campaign ? campaign.starts_on : today - Catalog::ROUTINE_BACKDATE_DAYS
        next Result.fail(:date_out_of_range, details: { path: "vaccinated_on" }) unless (earliest..today).cover?(attrs[:vaccinated_on])

        failure = animal!(attrs, by, origin)
        next failure if failure
        next invalid("vector_product_id") unless VectorProduct.where(active: true).where("? = ANY(uses)", VACCINE_USE)
                                                                                .exists?(id: attrs[:vector_product_id])
        next invalid("health_unit_id") if attrs[:health_unit_id] && !HealthUnit.exists?(id: attrs[:health_unit_id], active: true)

        vaccination = RabiesVaccination.create!(attrs.merge(recorded_by_user: by))
        stocked = ApplyStock.call(document: vaccination, product_id: vaccination.vector_product_id, kind: STOCK_KIND, by: by, today: today)
        movement = stocked.payload[:movement]
        vaccination.update!(stock_lot_id: movement.stock_lot_id) if movement
        DomainEvents.publish(EVENT, rabies_vaccination_id: vaccination.id)
        Result.ok(vaccination: vaccination)
      end
    end

    # Confere o animal (travado FOR SHARE), fixa a espécie e o domicílio da
    # dose em `attrs`. -> nil | Result de recusa.
    def animal!(attrs, by, origin)
      unless attrs[:animal_id]
        return invalid("animal_id") unless attrs[:modality] == "fixed_post"
        return invalid("species") unless Catalog::VACCINE_SPECIES.include?(attrs[:species])

        return nil
      end

      animal = Animal.lock("FOR SHARE").find_by(id: attrs[:animal_id])
      return invalid("animal_id") unless animal
      return Result.fail(:animal_not_active) unless animal.status == "active"
      return invalid("animal_id") unless Catalog::VACCINE_SPECIES.include?(animal.species)
      return invalid("species") if attrs.key?(:species) && attrs[:species] != animal.species

      attrs[:species] = animal.species
      return nil unless attrs[:modality] == "house"

      household = animal.household_id && Household.includes(micro_area: :team).find_by(id: animal.household_id)
      return invalid("animal_id") unless household
      return Result.fail(:out_of_scope) if origin == "field" && !Access.field_agent?(by, household)

      attrs[:household_id] = household.id
      nil
    end

    # Forma do corpo. -> { atributo => valor } | Result de recusa (só a primeira).
    def parse(params, origin)
      allowed = origin == "field" ? FIELD_KEYS : KEYS
      unknown = params.keys.find { |key| !allowed.include?(key) }
      return invalid(unknown.to_s[0, KEY_PATH_MAX]) if unknown

      missing = REQUIRED.find { |key| !params.key?(key) }
      return invalid(missing) if missing

      attrs = {}
      params.each do |key, value|
        parsed = parse_value(key, value)
        return invalid(key) if parsed.equal?(INVALID)

        attrs[key.to_sym] = parsed
      end
      modality = attrs[:modality]
      return invalid("modality") if origin == "field" && modality != "house"
      return invalid("campaign_id") if modality == "routine" ? params.key?("campaign_id") : attrs[:campaign_id].nil?
      return invalid("animal_id") if modality != "fixed_post" && attrs[:animal_id].nil?
      return invalid("health_unit_id") if modality == "house" && attrs[:health_unit_id]
      return invalid("adverse_note") if attrs[:adverse_note] && !attrs[:adverse_event]

      attrs.compact
    end

    def parse_value(key, value)
      case key
      when "modality" then Catalog::MODALITIES.include?(value) ? value : INVALID
      when "species" then Catalog::VACCINE_SPECIES.include?(value) ? value : INVALID
      when "campaign_id", "animal_id", "health_unit_id", "vector_product_id", "client_uuid" then uuid(value)
      when "vaccinated_on" then date(value)
      when "adverse_event" then [ true, false ].include?(value) ? value : INVALID
      when "adverse_note" then note(value)
      end
    end

    def uuid(value)
      return nil if value.nil?

      value.is_a?(String) && value.match?(UUID) ? value.downcase : INVALID
    end

    def date(value)
      return INVALID unless value.is_a?(String) && value.match?(DATE)

      Date.strptime(value, "%Y-%m-%d")
    rescue Date::Error
      INVALID
    end

    def note(value)
      return nil if value.nil?
      return INVALID unless value.is_a?(String)

      clean = value.strip
      Catalog::NOTE.cover?(clean.length) ? clean : INVALID
    end

    def invalid(path) = Result.fail(:invalid_request, details: { path: path })

    private_class_method :record, :animal!, :parse, :parse_value, :uuid, :date, :note, :invalid
  end
end
