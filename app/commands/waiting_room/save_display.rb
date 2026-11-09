# Cria e edita a TV de uma unidade (ADR 0050; contrato §8 e §14 Q8; plano,
# Task 12): nome de 1 a 60 caracteres, `active` e `show_wait_times`
# (booleanos; os tempos por cor só saem numa UPA com o flag da unidade também
# ligado). Unidade ativa e nunca CAPS (P32); não muda depois de criada.
# `active: false` revoga o token vivo (evento waiting_room.display_revoked) e
# descarta o código pendente; reativar não devolve o token — a TV é pareada de
# novo. Chave fora das conhecidas (os digests inclusive) → invalid_request.
module WaitingRoom
  module SaveDisplay
    NAME = (1..60)
    KEYS = %w[health_unit_id name active show_wait_times].freeze

    module_function

    # attrs: corpo JSON (chaves texto). -> Result.ok(display:) |
    # fail(:invalid_request, details: { path:, problems: }) | fail(:caps_unit_not_allowed)
    def call(attrs:, by:, display: nil)
      attrs = attrs.to_h.stringify_keys
      unknown = (attrs.keys - KEYS).first
      return Fields.refuse(unknown) if unknown

      %w[active show_wait_times].each do |key|
        return Fields.refuse(key) if attrs.key?(key) && !Fields.boolean?(attrs[key])
      end

      display ? update(display, attrs) : create(attrs, by)
    end

    def create(attrs, by)
      name = Fields.name(attrs["name"], NAME)
      return Fields.refuse("name") unless name

      unit = Fields.unit(attrs["health_unit_id"])
      return Fields.refuse("health_unit_id") unless unit
      return Result.fail(:caps_unit_not_allowed) if unit.caps?

      display = WaitingRoomDisplay.create!(health_unit: unit, name: name, active: attrs.fetch("active", true),
                                           show_wait_times: attrs.fetch("show_wait_times", true), created_by_user: by)
      Result.ok(display: display)
    end

    def update(display, attrs)
      return Fields.refuse("health_unit_id") if attrs.key?("health_unit_id") && attrs["health_unit_id"] != display.health_unit_id

      name = attrs.key?("name") ? Fields.name(attrs["name"], NAME) : display.name
      return Fields.refuse("name") unless name

      WaitingRoomDisplay.transaction(requires_new: true) do
        locked = WaitingRoomDisplay.lock.find(display.id)
        locked.assign_attributes(name: name, active: attrs.fetch("active", locked.active),
                                 show_wait_times: attrs.fetch("show_wait_times", locked.show_wait_times))
        Revoke.revoke!(locked) unless locked.active
        locked.save! if locked.changed?
        Result.ok(display: locked)
      end
    end

    private_class_method :create, :update
  end
end
