# Abertura de frasco multidose na sala (ADR 0047, Desvio 8; contrato §3; V14).
# Tira `doses_per_vial` doses do lote (movimento `vial_opening`, documento o
# próprio frasco) e vence em `opened_at` + a validade após aberto do fabricante
# do lote (pela `key`; lote sem fabricante resolvido ou fabricante fora do
# catálogo vale a MENOR validade do produto, a conservadora). Nenhuma regra de
# abertura além de lote da sala, do domínio imunobiológico, multidose, não
# vencido, não bloqueado e com saldo (NT 236/2026): nunca agendamento nem
# número mínimo de pessoas.
#
# Ordem de travas do módulo (Pharmacy::Ledger): lote → local → frasco. Bloqueio
# aberto e saldo são lidos de novo já sob a trava. Evento
# `vaccination.vial_opened` só com ids.
module Vaccination
  module OpenVial
    module_function

    # -> Result.ok(vial:) | fail(:lot_not_in_room | :not_multidose | :lot_expired | :lot_blocked | :insufficient_balance)
    # `lot` nil (inexistente) = :lot_not_in_room. Pressupõe `room` ativa (o controlador confere).
    def call(room:, lot:, by:, now: Time.current)
      return Result.fail(:lot_not_in_room) unless in_room?(room, lot)

      product = Immunobiologicals.find(lot.immunobiological_code)
      return Result.fail(:not_multidose) unless product&.multidose
      return Result.fail(:lot_expired) if lot.expires_on < now.in_time_zone.to_date

      result = nil
      VialOpening.transaction(requires_new: true) do
        result = write(room: room, lot: lot, product: product, by: by, now: now)
        raise ActiveRecord::Rollback if result.failure?
      end
      result
    end

    def write(room:, lot:, product:, by:, now:)
      locked = Pharmacy::Ledger.lock_lots!([ lot.id ]).fetch(lot.id)
      location = Pharmacy::Ledger.lock_location!(room.stock_location_id)
      return Result.fail(:lot_blocked) if StockLotBlock.open_blocks.exists?(stock_location_id: location.id, stock_lot_id: locked.id)

      doses = product.doses_per_vial
      return Result.fail(:insufficient_balance) if Pharmacy::Ledger.balance(location_id: location.id, lot_id: locked.id) < doses

      vial = VialOpening.create!(vaccine_room: room, stock_lot: locked, opened_by_user: by, opened_at: now, doses_per_vial: doses,
                                 expires_at: now + validity_hours(product, locked).hours)
      Pharmacy::Ledger.record!(location: location, lot: locked, kind: "vial_opening", quantity: doses, by: by, document: vial, at: now)
      DomainEvents.publish("vaccination.vial_opened", vial_opening_id: vial.id, vaccine_room_id: room.id, user_id: by.id)
      Result.ok(vial: vial)
    rescue Pharmacy::Ledger::Insufficient
      Result.fail(:insufficient_balance)
    rescue Pharmacy::Ledger::Inactive
      Result.fail(:lot_not_in_room)
    end

    # Lote do domínio de vacina com movimento no local da sala.
    def in_room?(room, lot)
      lot && Stock::Domain.immunobiological?(room.stock_location) && lot.immunobiological? &&
        StockMovement.exists?(stock_location_id: room.stock_location_id, stock_lot_id: lot.id)
    end

    # Horas de validade após aberto; sempre positivas (CHECK expires_at > opened_at).
    def validity_hours(product, lot)
      maker = product.manufacturer(lot.manufacturer_key)
      hours = maker ? [ maker.validity_after_opening_hours ] : product.manufacturers.map(&:validity_after_opening_hours)
      [ hours.min.to_i, 1 ].max
    end

    private_class_method :write, :in_room?, :validity_hours
  end
end
