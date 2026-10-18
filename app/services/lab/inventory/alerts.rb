# Alertas do estoque (spec §6.6; contrato §5), sem trilha: lotes com saldo
# vencendo dentro do expiry_alert_days do item (ou já vencidos); itens
# ativos abaixo do mínimo (saldo dos lotes não vencidos); resultados dos
# últimos 30 dias de exame com aparelho sem lote de reagente (sem rastreio).
module Lab
  module Inventory
    module Alerts
      UNTRACED_WINDOW = 30.days

      module_function

      def call(provider_id:, now: Time.current)
        today = now.in_time_zone.to_date
        balances = LabSupplyMovement.joins(lab_supply_lot: :lab_supply).where(lab_supplies: { exam_provider_id: provider_id })
                                    .group(:lab_supply_lot_id).sum(:quantity)
        lots = LabSupplyLot.where(id: balances.select { |_, b| b.positive? }.keys).includes(:lab_supply).to_a
        expiring = lots.select { |l| l.expires_on <= today + l.lab_supply.expiry_alert_days }.sort_by { |l| [ l.expires_on, l.lot_number ] }
        available = lots.reject { |l| l.expired?(today) }.group_by(&:lab_supply_id).transform_values { |ls| ls.sum { |l| balances[l.id] } }
        below = LabSupply.where(exam_provider_id: provider_id, active: true).order(:name).select { |s| available.fetch(s.id, 0) < s.minimum_stock }
        untraced = LabResult.joins(lab_requisition_item: [ :lab_requisition, :lab_exam_version ])
                            .where(lab_requisitions: { exam_provider_id: provider_id }, reagent_lot_id: nil, chosen: false)
                            .where.not(lab_exam_versions: { lab_instrument_id: nil })
                            .where("lab_results.created_at >= ?", now - UNTRACED_WINDOW).count
        { expiring: expiring.map { |l| Json.lot(l, balance: balances[l.id]).merge(lot_id: l.id) }, # forma C3: lot_id
          below_minimum: below.map { |s| Json.supply(s, balance: available.fetch(s.id, 0)).merge(supply_id: s.id) },
          untraced_results: untraced }
      end
    end
  end
end
