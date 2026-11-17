# Lotes do produto da vigilância ambiental em FEFO (módulo 35a, ADR 0054;
# contrato §4): os lotes do produto, não vencidos (a validade vale até o fim
# do dia), sem bloqueio aberto no local (StockLotBlock) e com saldo > 0 NO
# local, por `expires_on, lot_number, id`. Só leitura, sem trava: a baixa
# (VectorControl::DeductStock) reaproveita esta seleção, trava e relê.
module VectorControl
  module Fefo
    Entry = Struct.new(:lot, :balance)

    module_function

    # -> [Entry(lot: StockLot, balance: BigDecimal)]; sem local → [].
    def lots(product_id:, location:, today:)
      return [] if location.nil?

      candidates = StockLot.where(vector_product_id: product_id).where("expires_on >= ?", today)
                           .order(:expires_on, :lot_number, :id).to_a
      return [] if candidates.empty?

      ids = candidates.map(&:id)
      blocked = StockLotBlock.open_blocks.where(stock_location_id: location.id, stock_lot_id: ids).pluck(:stock_lot_id).to_set
      balances = Pharmacy::Ledger.balances(location_id: location.id, lot_ids: ids)
      candidates.filter_map do |lot|
        balance = balances.fetch(lot.id)
        Entry.new(lot, balance) if !blocked.include?(lot.id) && balance.positive?
      end
    end
  end
end
