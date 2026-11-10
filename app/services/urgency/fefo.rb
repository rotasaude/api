# Lotes da medicação da UPA em FEFO (contrato §5 e §12 Q5, Q6; plano, Desvio 7):
# os lotes do item, da mesma unidade de dispensação (`stock_unit`), não
# vencidos (a validade vale até o fim do dia), sem bloqueio aberto no local
# (StockLotBlock) e com saldo > 0 NO local, por `expires_on, lot_number, id`.
# Só leitura, sem trava: a baixa (Task 10) reaproveita esta seleção e acrescenta
# as travas (Ledger.lock_lots! e lock_location!) antes de reler o saldo.
module Urgency
  module Fefo
    Entry = Struct.new(:lot, :balance)

    module_function

    # -> [Entry(lot: StockLot, balance: BigDecimal)]; sem local → [].
    def lots(catalog_item_id:, stock_unit:, location:, today: Time.zone.today)
      return [] if location.nil?

      candidates = StockLot.where(catalog_item_id: catalog_item_id, dispensing_unit: stock_unit)
                           .where("expires_on >= ?", today).order(:expires_on, :lot_number, :id).to_a
      return [] if candidates.empty?

      blocked = StockLotBlock.open_blocks.where(stock_location_id: location.id, stock_lot_id: candidates.map(&:id)).pluck(:stock_lot_id).to_set
      balances = Pharmacy::Ledger.balances(location_id: location.id, lot_ids: candidates.map(&:id))
      candidates.filter_map do |lot|
        balance = balances.fetch(lot.id)
        Entry.new(lot, balance) if !blocked.include?(lot.id) && balance.positive?
      end
    end

    # O local de estoque `unit` ATIVO da UPA (inativo ou ausente → nil).
    def location_for(unit_id)
      StockLocation.find_by(kind: "unit", health_unit_id: unit_id, active: true)
    end
  end
end
