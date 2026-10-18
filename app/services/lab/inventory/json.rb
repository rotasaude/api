# Formas do estoque (contrato §5). Quantidades inteiras (embalagens), saldo = soma dos movimentos.
module Lab
  module Inventory
    module Json
      module_function

      # below_minimum (C-E28): só o saldo dos lotes NÃO vencidos conta; o
      # vencido tem o alerta próprio.
      def supply(s, balance: nil, available: nil)
        balance ||= LabSupplyMovement.joins(:lab_supply_lot).where(lab_supply_lots: { lab_supply_id: s.id }).sum(:quantity)
        available ||= available_balances([ s.id ]).fetch(s.id, 0)
        { id: s.id, provider_id: s.exam_provider_id, name: s.name, kind: s.kind, unit: s.unit, tests_per_package: s.tests_per_package,
          minimum_stock: s.minimum_stock, expiry_alert_days: s.expiry_alert_days, lab_exam_ids: s.lab_exam_ids, active: s.active,
          balance: balance, below_minimum: available < s.minimum_stock }
      end

      # Saldo por item só dos lotes com validade de hoje em diante.
      def available_balances(supply_ids, today: Time.current.in_time_zone.to_date)
        LabSupplyMovement.joins(:lab_supply_lot).where(lab_supply_lots: { lab_supply_id: supply_ids })
                         .where("lab_supply_lots.expires_on >= ?", today).group("lab_supply_lots.lab_supply_id").sum(:quantity)
      end

      def lot(l, balance: l.balance)
        { id: l.id, supply_id: l.lab_supply_id, supply_name: l.lab_supply.name, lot_number: l.lot_number, expires_on: l.expires_on.iso8601,
          supplier: l.supplier, origin: l.origin, balance: balance, expired: l.expired?,
          in_use: LabSupplyInUse.current.where(lab_supply_lot_id: l.id).map { |u| { instrument_id: u.lab_instrument_id, lab_exam_id: u.lab_exam_id } } }
      end

      def movement(m, balance: nil)
        body = { id: m.id, lot_id: m.lab_supply_lot_id, kind: m.kind, quantity: m.quantity, reason: m.reason, document: m.document,
                 recorded_at: m.recorded_at.iso8601, recorded_by: Screenings::Json.staff_name(m.recorded_by_user) }
        body[:balance] = balance unless balance.nil?
        body
      end
    end
  end
end
