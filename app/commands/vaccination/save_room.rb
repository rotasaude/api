# Cria e edita a sala de vacina de uma unidade (ADR 0047; §15 V2/V14). A sala
# nasce com o local de estoque `vaccine_room` ("<nome> — <unidade>") na mesma
# transação; uma por unidade (`unit_taken`). Nome de 3 a 120 caracteres,
# recusado, nunca cortado. Desativar trava os lotes ANTES do local (ordem de
# travas do módulo) e recusa `location_has_stock` com saldo > 0, frasco aberto
# ou transferência/ajuste pendente; desativa o local junto. Evento
# `vaccine_room.saved` só com ids, e só quando algo mudou.
module Vaccination
  module SaveRoom
    NAME_LENGTH = (3..Pharmacy::Catalog::NAME_MAX)
    LOCATION_NAME_MAX = 120
    UNIT_INDEX = "idx_vaccine_rooms_unit".freeze

    module_function

    # attrs: corpo JSON (chaves texto). -> Result.ok(room:) |
    # fail(:invalid_request, details: { path: }) | fail(:unit_taken) | fail(:location_has_stock).
    def call(attrs:, by:, room: nil)
      attrs = attrs.to_h.stringify_keys
      room ? update(room, attrs, by) : create(attrs, by)
    rescue ActiveRecord::RecordNotUnique => e
      e.message.include?(UNIT_INDEX) ? Result.fail(:unit_taken) : refuse("name")
    end

    def create(attrs, by)
      name = valid_name(attrs["name"])
      return refuse("name") unless name

      active = attrs.fetch("active", true)
      return refuse("active") unless [ true, false ].include?(active)
      return refuse("health_unit_id") unless attrs["health_unit_id"].is_a?(String)

      VaccineRoom.transaction(requires_new: true) do
        unit = HealthUnit.where(active: true).lock.find_by(id: attrs["health_unit_id"])
        next refuse("health_unit_id") unless unit
        next Result.fail(:unit_taken) if VaccineRoom.exists?(health_unit_id: unit.id)

        location_name = location_name(name, unit)
        next refuse("name") if name_taken?(location_name)

        location = StockLocation.create!(kind: "vaccine_room", name: location_name, health_unit_id: unit.id, active: active, updated_by_user: by)
        room = VaccineRoom.create!(health_unit: unit, stock_location: location, name: name, active: active, updated_by_user: by)
        publish(room, by)
        Result.ok(room: room)
      end
    end

    def update(room, attrs, by)
      name = attrs.key?("name") ? valid_name(attrs["name"]) : nil
      return refuse("name") if attrs.key?("name") && name.nil?
      return refuse("active") if attrs.key?("active") && ![ true, false ].include?(attrs["active"])
      return refuse("health_unit_id") if attrs.key?("health_unit_id") && attrs["health_unit_id"] != room.health_unit_id

      VaccineRoom.transaction(requires_new: true) do
        # Passo 1: os lotes (lote → local), só quando a chamada desativa.
        Pharmacy::Ledger.lock_lots!(lot_ids_of(room.stock_location)) if attrs["active"] == false
        # Passo 2: a sala e o local, relidos sob FOR UPDATE.
        locked = VaccineRoom.lock.find(room.id)
        location = StockLocation.lock.find(locked.stock_location_id)
        active = attrs.key?("active") ? attrs["active"] : locked.active
        new_name = name || locked.name
        location_name = location_name(new_name, locked.health_unit)
        next refuse("name") if location_name != location.name && name_taken?(location_name, except: location.id)
        next Result.fail(:location_has_stock) if locked.active && !active && (stocked?(location) || open_vial?(locked) || pending_work?(location))

        locked.assign_attributes(name: new_name, active: active)
        location.assign_attributes(name: location_name, active: active)
        if locked.changed? || location.changed?
          locked.updated_by_user = by
          location.updated_by_user = by
          locked.save!
          location.save!
          publish(locked, by)
        end
        Result.ok(room: locked)
      end
    end

    def lot_ids_of(location) = StockMovement.where(stock_location_id: location.id).distinct.pluck(:stock_lot_id)

    # Saldo > 0 em algum lote, lido com o local já travado.
    def stocked?(location)
      Pharmacy::Ledger.balances(location_id: location.id, lot_ids: lot_ids_of(location)).values.any?(&:positive?)
    end

    def open_vial?(room) = VialOpening.where(vaccine_room_id: room.id, closed_at: nil).exists?
    def pending_work?(location) = Pharmacy::PendingWork.any?(location)

    def valid_name(value)
      return nil unless value.is_a?(String)

      name = value.strip
      NAME_LENGTH.cover?(name.length) ? name : nil
    end

    # "<nome> — <unidade>", dentro dos 120 do local (a sala guarda o nome inteiro).
    def location_name(name, unit) = "#{name} — #{unit.name}".truncate(LOCATION_NAME_MAX, omission: "")

    # Único sem diferenciar caixa (idx_stock_locations_name_ci).
    def name_taken?(name, except: nil)
      scope = StockLocation.where("lower(name) = lower(?)", name)
      (except ? scope.where.not(id: except) : scope).exists?
    end

    def publish(room, by)
      DomainEvents.publish("vaccine_room.saved", vaccine_room_id: room.id, user_id: by.id)
    end

    def refuse(path) = Result.fail(:invalid_request, details: { path: path, problems: [ { path: path, error: "invalid_request" } ] })

    private_class_method :create, :update, :lot_ids_of, :stocked?, :open_vial?, :pending_work?, :valid_name, :location_name, :name_taken?,
                         :publish, :refuse
  end
end
