# Pendência de um local de estoque (ADR 0045; contrato H14): transferência
# `sent` (origem OU destino no local) ou ajuste `pending` do local. Uma regra
# só para quem desativa: o local (Pharmacy::SaveLocation) e a unidade de saúde
# dona dele (HealthUnitsController#deactivate).
#
# Leitura simples, sem trava própria: quem chama já segura a trava que
# serializa as escritas. Quem grava `sent`/`pending` pega FOR SHARE no local e
# na unidade (Ledger.lock_location!), então ou o chamador vê a pendência
# commitada, ou a escrita relê o local/unidade já inativo e recusa.
module Pharmacy
  module PendingWork
    module_function

    def any?(location)
      StockTransfer.where(status: "sent").where("from_location_id = :id OR to_location_id = :id", id: location.id).exists? ||
        StockAdjustment.where(stock_location_id: location.id, status: "pending").exists?
    end
  end
end
