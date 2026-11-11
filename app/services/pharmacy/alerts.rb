# Contagens de alerta de um local (ADR 0045; contrato §9 e H10/H12): sem trilha
# e sem dado pessoal. As listas da tela vêm da posição.
#
# - `expiring`: lotes com saldo > 0 que vencem de hoje até hoje + expiry_alert_days
#   (os já vencidos NÃO entram: têm contagem própria);
# - `expired`: lotes com saldo > 0 e validade < hoje;
# - `below_minimum`: itens com mínimo > 0 e saldo < mínimo (a mesma conta da
#   posição, inclusive item sem movimento);
# - `in_transit`: transferências `sent` com destino no local, à espera do recebimento;
# - `pending_adjustments`: ajustes `pending` do local, à espera de aprovação;
# - `urgency_shortfalls` (módulo 32b, Task 11): faltas de estoque da UPA em aberto no local;
#   no local central, somadas às `no_location` em aberto de todas as UPAs (Q14: quem
#   lê e concilia essas faltas é o central, Q7).
module Pharmacy
  module Alerts
    module_function

    # -> { expiring:, expired:, below_minimum:, in_transit:, pending_adjustments:, urgency_shortfalls: } (inteiros)
    def call(location:, today:, settings:)
      cutoff = today + settings.expiry_alert_days
      lots = Positions.query(<<~SQL.squish, location_ids: [ location.id ], item_ids: nil, cutoff: cutoff, binds: { today: today }).first
        SELECT
          (SELECT COUNT(*) FROM lots l JOIN stock_lots sl ON sl.id = l.lot_id
             WHERE l.balance > 0 AND sl.expires_on >= :today AND sl.expires_on <= :cutoff) AS expiring,
          (SELECT COUNT(*) FROM lots l JOIN stock_lots sl ON sl.id = l.lot_id
             WHERE l.balance > 0 AND sl.expires_on < :today) AS expired,
          (SELECT COUNT(*) FROM flagged WHERE below_minimum) AS below_minimum
      SQL
      { expiring: lots["expiring"].to_i, expired: lots["expired"].to_i, below_minimum: lots["below_minimum"].to_i,
        in_transit: StockTransfer.where(status: "sent", to_location_id: location.id).count,
        pending_adjustments: StockAdjustment.where(status: "pending", stock_location_id: location.id).count,
        urgency_shortfalls: urgency_shortfalls(location) }
    end

    def urgency_shortfalls(location)
      scope = UrgencyStockShortfall.open_shortfalls
      scope = location.central? ? scope.where(stock_location_id: [ location.id, nil ]) : scope.where(stock_location_id: location.id)
      scope.count
    end
  end
end
