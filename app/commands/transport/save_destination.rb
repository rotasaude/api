# Cadastra e edita destinos de viagem (ADR 0048; contrato §4): município (IBGE,
# 7 dígitos, único), nome 2–120, distância em km a partir da cidade (0 =
# intramunicipal) e a marca de região metropolitana (o TFD recusa). Todas as
# recusas de campo de uma vez; IBGE repetido → :ibge_taken. Nunca se apaga:
# desativa-se. Evento só com ids.
module Transport
  module SaveDestination
    KEYS = %w[ibge_code name distance_km metropolitan active].freeze

    module_function

    # -> Result.ok(destination:) | fail(:invalid_request, details: { path:, problems: }) | fail(:ibge_taken)
    def call(attrs:, by:, record: nil)
      attrs = attrs.to_h.stringify_keys.slice(*KEYS)
      clean, bad = validate(attrs, record)
      return Support.refuse(bad) if bad.any?

      TransportDestination.transaction(requires_new: true) do
        destination = record || TransportDestination.new
        destination.lock! if record
        destination.assign_attributes(clean)
        next Result.ok(destination: destination) if record && !destination.changed?

        destination.updated_by_user = by
        destination.save!
        DomainEvents.publish("transport.destination_saved", destination_id: destination.id, user_id: by.id)
        Result.ok(destination: destination)
      end
    rescue ActiveRecord::RecordNotUnique
      Result.fail(:ibge_taken)
    end

    # Criação: tudo obrigatório, menos `metropolitan` (padrão false) e `active`
    # (padrão true). Edição: só o que veio.
    def validate(attrs, record)
      clean = {}
      bad = []
      rules = {
        "ibge_code" => ->(v) { v.is_a?(String) && v.strip.match?(Catalog::IBGE) ? v.strip : nil },
        "name" => ->(v) { Support.text(v, Catalog::NAME) },
        "distance_km" => ->(v) { Support.integer(v, Catalog::DISTANCE_KM) }
      }
      rules.each do |key, rule|
        next if record && !attrs.key?(key)

        value = rule.call(attrs[key])
        value.nil? ? bad << key : clean[key] = value
      end
      { "metropolitan" => false, "active" => true }.each do |key, default|
        next if record && !attrs.key?(key)

        value = attrs.fetch(key, default)
        Support.boolean?(value) ? clean[key] = value : bad << key
      end
      [ clean, bad ]
    end

    private_class_method :validate
  end
end
