# Cadastra e edita locais de estoque (ADR 0045; contrato §3): o almoxarifado
# central (um só na cidade) e a farmácia de cada unidade. Tipo e unidade não
# mudam depois de criados; nome de 3 a 120 caracteres, recusado, nunca cortado,
# e único sem diferenciar caixa. Criar ou ativar um local de unidade grava
# `health_units.dispenses = true`; desativar grava `false` (mesma transação).
#
# Desativar com saldo > 0 em algum lote, com transferência `sent` (origem OU
# destino no local) ou com ajuste `pending` em lote do local → `location_has_stock`
# (um código só: o local ainda tem o que resolver). A ordem de
# travas do módulo vale aqui: LOTES → LOCAL (a dispensação trava os lotes, depois
# o local com FOR SHARE; travar o local primeiro, com FOR UPDATE, cruzaria com
# ela). Por isso a desativação trava os lotes do local ANTES do local e só então
# confere o saldo, já sob a trava do local: nenhum movimento novo entra sem o
# FOR SHARE dele. Evento `pharmacy.settings_changed` só com ids, e só quando
# algo mudou.
module Pharmacy
  module SaveLocation
    NAME_LENGTH = (3..Catalog::NAME_MAX)
    # Índices únicos da migração 20261029900001.
    CENTRAL_INDEX = "idx_stock_locations_one_central".freeze
    UNIT_INDEX = "idx_stock_locations_unit".freeze

    module_function

    # attrs: corpo JSON (chaves texto). -> Result.ok(location:) |
    # fail(:invalid_request, details: { path: }) | fail(:central_exists) |
    # fail(:unit_taken) | fail(:location_has_stock).
    def call(attrs:, by:, location: nil)
      attrs = attrs.to_h.stringify_keys
      location ? update(location, attrs, by) : create(attrs, by)
    rescue ActiveRecord::RecordNotUnique => e
      conflict(e)
    end

    def create(attrs, by)
      kind = attrs["kind"]
      return refuse("kind") unless Catalog::LOCATION_KINDS.include?(kind)

      name = valid_name(attrs["name"])
      return refuse("name") unless name

      active = attrs.fetch("active", true)
      return refuse("active") unless [ true, false ].include?(active)

      unit_id = attrs["health_unit_id"]
      return refuse("health_unit_id") unless kind == "central" ? unit_id.nil? : unit_id.is_a?(String)

      StockLocation.transaction(requires_new: true) do
        unit = kind == "unit" ? lock_unit(unit_id) : nil
        next refuse("health_unit_id") if kind == "unit" && unit.nil?
        next Result.fail(:central_exists) if kind == "central" && StockLocation.exists?(kind: "central")
        next Result.fail(:unit_taken) if unit && StockLocation.exists?(health_unit_id: unit.id)
        next refuse("name") if name_taken?(name)

        location = StockLocation.create!(kind: kind, name: name, health_unit_id: unit&.id, active: active, updated_by_user: by)
        mark_dispenses(unit, active) if unit
        publish(location, by)
        Result.ok(location: location)
      end
    end

    def update(location, attrs, by)
      return refuse("kind") if attrs.key?("kind") && attrs["kind"] != location.kind
      return refuse("health_unit_id") if attrs.key?("health_unit_id") && attrs["health_unit_id"] != location.health_unit_id

      name = attrs.key?("name") ? valid_name(attrs["name"]) : nil
      return refuse("name") if attrs.key?("name") && name.nil?
      return refuse("active") if attrs.key?("active") && ![ true, false ].include?(attrs["active"])

      StockLocation.transaction(requires_new: true) do
        # Passo 1: os lotes (lote → local), só quando a chamada desativa.
        lock_lots_of(location) if attrs["active"] == false
        # Passo 2: o local, relido sob FOR UPDATE; o estado de decisão é o relido.
        locked = StockLocation.lock.find(location.id)
        active = attrs.key?("active") ? attrs["active"] : locked.active
        next refuse("name") if name && name != locked.name && name_taken?(name, except: locked.id)
        next Result.fail(:location_has_stock) if locked.active && !active && (stocked?(locked) || pending_work?(locked))

        outcome = apply(locked, name: name, active: active, by: by)
        outcome.is_a?(Result) ? outcome : Result.ok(location: outcome)
      end
    end

    # -> StockLocation (salvo, evento publicado quando mudou) | Result (recusa)
    def apply(locked, name:, active:, by:)
      locked.name = name if name
      activating = !locked.active && active
      deactivating = locked.active && !active
      locked.active = active
      return locked unless locked.changed?

      if locked.unit? && (activating || deactivating)
        unit = activating ? lock_unit(locked.health_unit_id) : HealthUnit.lock.find_by(id: locked.health_unit_id)
        return refuse("active") if activating && unit.nil?

        mark_dispenses(unit, active) if unit
      end
      locked.updated_by_user = by
      locked.save!
      publish(locked, by)
      locked
    end

    # Unidade ATIVA, travada para escrita (a marca `dispenses` muda e a
    # desativação da unidade trava a mesma linha).
    def lock_unit(id)
      HealthUnit.where(active: true).lock.find_by(id: id)
    end

    def mark_dispenses(unit, value)
      return if unit.dispenses == value

      unit.update_columns(dispenses: value, updated_at: Time.current)
    end

    def lot_ids_of(location) = StockMovement.where(stock_location_id: location.id).distinct.pluck(:stock_lot_id)
    def lock_lots_of(location) = Ledger.lock_lots!(lot_ids_of(location))

    # Saldo > 0 em algum lote, lido com o local já travado.
    def stocked?(location)
      Ledger.balances(location_id: location.id, lot_ids: lot_ids_of(location)).values.any?(&:positive?)
    end

    # Transferência enviada e ainda não recebida (de ou para o local) ou ajuste
    # por decidir num lote do local; lido com o local já travado. A regra é
    # compartilhada com a desativação da unidade de saúde (H14).
    def pending_work?(location) = PendingWork.any?(location)

    def valid_name(value)
      return nil unless value.is_a?(String)

      name = value.strip
      NAME_LENGTH.cover?(name.length) ? name : nil
    end

    # Único sem diferenciar caixa (idx_stock_locations_name_ci).
    def name_taken?(name, except: nil)
      scope = StockLocation.where("lower(name) = lower(?)", name)
      (except ? scope.where.not(id: except) : scope).exists?
    end

    # O banco acusa o primeiro índice que viu: central, unidade ou nome.
    def conflict(error)
      return Result.fail(:central_exists) if error.message.include?(CENTRAL_INDEX)
      return Result.fail(:unit_taken) if error.message.include?(UNIT_INDEX)

      refuse("name")
    end

    def publish(location, by)
      DomainEvents.publish("pharmacy.settings_changed", subject: "location", stock_location_id: location.id, user_id: by.id)
    end

    def refuse(path) = Result.fail(:invalid_request, details: { path: path })

    private_class_method :create, :update, :apply, :lock_unit, :mark_dispenses, :lot_ids_of, :lock_lots_of, :stocked?, :pending_work?, :valid_name,
                         :name_taken?, :conflict, :publish, :refuse
  end
end
