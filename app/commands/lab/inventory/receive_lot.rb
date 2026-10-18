# Entrada de lote (spec §6.2; contrato §5): número (1..40), validade
# (vencido recusado), fornecedor (1..120), origem, quantidade (1..100000) e
# documento opcional (até 60). Mesmo número com a mesma validade = nova
# entrada no lote existente; com outra validade = duplicate_lot. Item
# travado, depois o lote.
module Lab
  module Inventory
    module ReceiveLot
      module_function

      def call(params, by:, now: Time.current)
        params = params.to_h.stringify_keys
        supply = params["supply_id"].to_s.match?(Exams::BaseController::UUID) ? LabSupply.find_by(id: params["supply_id"]) : nil
        return Result.fail(:not_found) unless supply

        number = params["lot_number"].is_a?(String) ? params["lot_number"].strip : ""
        supplier = params["supplier"].is_a?(String) ? params["supplier"].strip : ""
        document = params["document"].is_a?(String) ? params["document"].strip.presence : nil
        return Result.fail(:invalid_lot_number) unless number.length.between?(1, 40)
        return Result.fail(:invalid_supplier) unless supplier.length.between?(1, 120)
        return Result.fail(:invalid_origin) unless LabSupplyLot::ORIGINS.include?(params["origin"])
        return Result.fail(:invalid_quantity) unless params["quantity"].is_a?(Integer) && params["quantity"].between?(1, 100_000)
        return Result.fail(:invalid_document) if document && document.length > 60

        expires_on = Lab::IsoDate.parse(params["expires_on"])
        return Result.fail(:invalid_expires_on) unless expires_on
        return Result.fail(:expired_lot) if expires_on < now.in_time_zone.to_date

        ApplicationRecord.transaction(requires_new: true) do
          supply.lock!
          lot = LabSupplyLot.find_by(lab_supply_id: supply.id, lot_number: number)
          next Result.fail(:duplicate_lot) if lot && lot.expires_on != expires_on

          lot ||= LabSupplyLot.create!(lab_supply: supply, lot_number: number, expires_on: expires_on, supplier: supplier,
                                       origin: params["origin"], created_by_user: by, created_at: now)
          lot.lock!
          LabSupplyMovement.create!(lab_supply_lot: lot, kind: "receipt", quantity: params["quantity"], document: document,
                                    recorded_by_user: by, recorded_at: now, created_at: now)
          DomainEvents.publish(
            "lab_supply_lot.received",
            lab_supply_lot_id: lot.id, lab_supply_id: supply.id
          )
          Result.ok(lot: lot)
        end
      end
    end
  end
end
