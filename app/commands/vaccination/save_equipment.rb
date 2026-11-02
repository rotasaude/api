# Cria e edita o equipamento da cadeia de frio de um local de vacina (ADR
# 0047; contrato §8; §15 V14): nome de 3 a 120 caracteres (recusado, nunca
# cortado), tipo em EQUIPMENT_KINDS, mínima < máxima (uma casa decimal; padrão
# +2 a +8 °C na criação) e ativo. O local não muda depois de criado. Quem pode
# (room_lead da sala, stock_keeper da rede de frio) é do controlador. Nunca é
# apagado: desativa-se.
module Vaccination
  module SaveEquipment
    NAME_LENGTH = (3..Catalog::TEXT_MAX)
    FIELDS = %w[location_id name kind min_c max_c active].freeze

    module_function

    # attrs: corpo JSON (chaves texto). -> Result.ok(equipment:) |
    # fail(<erro>, details: { path:, problems: [ { path:, error: } ] })
    def call(attrs:, location: nil, equipment: nil)
      attrs = attrs.to_h.stringify_keys
      problems = []
      problems << problem("location_id", :invalid_request) if equipment && attrs.key?("location_id") && attrs["location_id"] != equipment.stock_location_id

      name = attrs.key?("name") || !equipment ? valid_name(attrs["name"]) : equipment.name
      problems << problem("name", :invalid_request) unless name
      kind = attrs.key?("kind") || !equipment ? attrs["kind"] : equipment.kind
      problems << problem("kind", :invalid_request) unless Catalog::EQUIPMENT_KINDS.include?(kind)
      min_c = temperature(attrs, "min_c", equipment&.min_c || Catalog::DEFAULT_RANGE_C.first, problems)
      max_c = temperature(attrs, "max_c", equipment&.max_c || Catalog::DEFAULT_RANGE_C.last, problems)
      problems << problem("max_c", :invalid_range) if min_c && max_c && min_c >= max_c
      active = attrs.key?("active") ? attrs["active"] : (equipment ? equipment.active : true)
      problems << problem("active", :invalid_request) unless [ true, false ].include?(active)
      return failure(problems) if problems.any?

      record = equipment || ColdChainEquipment.new(stock_location: location)
      record.assign_attributes(name: name, kind: kind, min_c: min_c, max_c: max_c, active: active)
      record.save! if record.changed?
      Result.ok(equipment: record)
    end

    def valid_name(raw)
      clean = raw.is_a?(String) ? raw.strip : nil
      clean if clean && NAME_LENGTH.cover?(clean.length)
    end

    def temperature(attrs, key, fallback, problems)
      return fallback.to_d unless attrs.key?(key)

      Temperature.parse(attrs[key]).tap { |value| problems << problem(key, :invalid_request) unless value }
    end

    def problem(path, error) = { path: path, error: error.to_s }

    def failure(problems)
      first = problems.first
      Result.fail(first[:error], details: { path: first[:path], problems: problems })
    end

    private_class_method :valid_name, :temperature, :problem, :failure
  end
end
