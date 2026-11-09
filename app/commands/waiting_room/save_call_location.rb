# Cria e edita o local de chamada de uma unidade (ADR 0050; contrato §8 e §14
# Q7; plano, Task 12): "Consultório 1", "Classificação". Nome de 1 a 40
# caracteres, recusado, nunca cortado; único na unidade sem diferença de caixa
# (409 call_location_name_taken); unidade ativa e nunca CAPS (P32). A unidade
# não muda depois de criado; desativado, nunca apagado (trigger). Chave fora
# das conhecidas → invalid_request com o path (P23). Sem evento.
module WaitingRoom
  module SaveCallLocation
    NAME = (1..40)
    KEYS = %w[health_unit_id name active].freeze
    NAME_INDEX = "idx_call_locations_name".freeze

    module_function

    # attrs: corpo JSON (chaves texto). -> Result.ok(call_location:) |
    # fail(:invalid_request, details: { path:, problems: }) | fail(:caps_unit_not_allowed) |
    # fail(:call_location_name_taken)
    def call(attrs:, by:, location: nil)
      attrs = attrs.to_h.stringify_keys
      unknown = (attrs.keys - KEYS).first
      return Fields.refuse(unknown) if unknown

      location ? update(location, attrs, by) : create(attrs, by)
    rescue ActiveRecord::RecordNotUnique => e
      raise unless e.message.include?(NAME_INDEX)

      Result.fail(:call_location_name_taken)
    end

    def create(attrs, by)
      name = Fields.name(attrs["name"], NAME)
      return Fields.refuse("name") unless name
      return Fields.refuse("active") unless Fields.boolean?(attrs.fetch("active", true))

      unit = Fields.unit(attrs["health_unit_id"])
      return Fields.refuse("health_unit_id") unless unit
      return Result.fail(:caps_unit_not_allowed) if unit.caps?

      CallLocation.transaction(requires_new: true) do
        location = CallLocation.create!(health_unit: unit, name: name, active: attrs.fetch("active", true), updated_by_user: by)
        Result.ok(call_location: location)
      end
    end

    def update(location, attrs, by)
      return Fields.refuse("health_unit_id") if attrs.key?("health_unit_id") && attrs["health_unit_id"] != location.health_unit_id

      name = attrs.key?("name") ? Fields.name(attrs["name"], NAME) : location.name
      return Fields.refuse("name") unless name
      return Fields.refuse("active") if attrs.key?("active") && !Fields.boolean?(attrs["active"])

      CallLocation.transaction(requires_new: true) do
        locked = CallLocation.lock.find(location.id)
        locked.assign_attributes(name: name, active: attrs.fetch("active", locked.active))
        if locked.changed?
          locked.updated_by_user = by
          locked.save!
        end
        Result.ok(call_location: locked)
      end
    end

    private_class_method :create, :update
  end
end
