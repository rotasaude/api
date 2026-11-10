# Baixa de estoque da checagem da UPA (ADR 0050; contrato §6 e §12 Q6; plano,
# Desvio 7; R7): escolhe o local, o lote e a quantidade de UMA administração —
# um lote só, sem fracionar (A10) — ou a causa da falta (A11). Não grava nada:
# quem grava é o Urgency::RecordAdministration, no savepoint
# { administração com lote e quantidade; Ledger.record! }.
#
# Ordem de trava. Chega aqui com as travas da urgência (atendimento →
# encontro → prescrição → itens do medicamento) e segue a do Ledger:
# LOTES (Ledger.lock_lots!, FOR UPDATE em ordem de id) → LOCAL
# (Ledger.lock_location!, FOR SHARE) → o documento (a administração, gravada
# depois). O saldo, o bloqueio e a validade valem RELIDOS sob a trava do lote:
# duas checagens do último comprimido leem saldo 1 no FEFO, mas só a primeira
# acha saldo depois da trava; a segunda vira falta insufficient_balance.
#
# Por que o savepoint (no chamador): o trigger rota_stock_balance_guard é a
# rede da conta daqui. Se ele recusar (Ledger::Insufficient), só o savepoint
# volta — a administração com lote some — e a checagem é gravada de novo sem
# lote, com a falta lot_unavailable. A checagem nunca é recusada por falta de
# estoque e o razão nunca fica negativo.
#
# Local: o StockLocation `unit` ATIVO da UPA (Fefo.location_for); ausente,
# inativo ou desativado até a trava (Ledger::Inactive) → no_location, sem local.
# Sem lote no corpo: o FEFO (Urgency::Fefo.lots) — o primeiro com saldo ≥
# quantidade sob a trava; nenhum → insufficient_balance.
# Lote do corpo (§12 Q12, que corrige o §6 item 2): inexistente, de outro item,
# de outra unidade de dispensação (`stock_unit` do item) ou vencido →
# lot_invalid (antes do local); de outro local → lot_invalid — no 27a o lote é
# do catálogo, e só "está" num local pelos movimentos: sem movimento algum no
# local `unit` da UPA, é de outro local; com bloqueio aberto no local (relido
# sob a trava) → lot_invalid. Válido mas já consumido (saldo < quantidade sob a
# trava, inclusive 0): a checagem NÃO é recusada — vale o próximo lote do FEFO
# (os candidatos travados junto com o do corpo, numa só chamada em ordem de
# id); nenhum → falta lot_unavailable.
module Urgency
  module DeductStock
    module_function

    # `lot_id`: uuid em minúsculas ou nil; `quantity`: BigDecimal > 0.
    # -> Result.ok(location:, lot:, quantity:) | Result.ok(shortfall_cause:, location:, quantity:) |
    #    Result.fail(:lot_invalid, details: { path: "stock_lot_id", problems: })
    def call(item:, unit_id:, lot_id:, quantity:, today:)
      lot_id ? chosen(item, unit_id, lot_id, quantity, today) : fefo(item, unit_id, quantity, today)
    rescue Pharmacy::Ledger::Inactive
      shortfall("no_location", nil, quantity)
    end

    def fefo(item, unit_id, quantity, today)
      location = Fefo.location_for(unit_id)
      return shortfall("no_location", nil, quantity) unless location

      locked, location = lock(item, location, today)
      lot = first_with_balance(item, location, quantity, today, locked)
      return shortfall("insufficient_balance", location, quantity) unless lot

      Result.ok(location: location, lot: lot, quantity: quantity)
    end

    def chosen(item, unit_id, lot_id, quantity, today)
      lot = StockLot.find_by(id: lot_id)
      return invalid unless lot && lot.catalog_item_id == item.catalog_item_id && lot.dispensing_unit == item.stock_unit &&
                            lot.expires_on >= today

      location = Fefo.location_for(unit_id)
      return shortfall("no_location", nil, quantity) unless location
      # Outro local: nenhum movimento do lote no local da UPA (só acréscimo, então vale lido antes da trava).
      return invalid unless StockMovement.exists?(stock_location_id: location.id, stock_lot_id: lot.id)

      locked, location = lock(item, location, today, extra: lot.id)
      return invalid if StockLotBlock.open_blocks.exists?(stock_location_id: location.id, stock_lot_id: lot.id)
      if Pharmacy::Ledger.balance(location_id: location.id, lot_id: lot.id) >= quantity
        return Result.ok(location: location, lot: locked.fetch(lot.id), quantity: quantity)
      end

      # Q12: consumido por outra checagem — o próximo lote do FEFO, senão a falta.
      fallback = first_with_balance(item, location, quantity, today, locked, except: lot.id)
      return shortfall("lot_unavailable", location, quantity) unless fallback

      Result.ok(location: location, lot: fallback, quantity: quantity)
    end

    # Ordem de trava: LOTES (os candidatos do FEFO e o do corpo, numa só
    # chamada, em ordem de id) → LOCAL. -> [{ id => StockLot }, StockLocation]
    def lock(item, location, today, extra: nil)
      candidates = Fefo.lots(catalog_item_id: item.catalog_item_id, stock_unit: item.stock_unit, location: location, today: today)
      locked = Pharmacy::Ledger.lock_lots!(candidates.map { |entry| entry.lot.id } + [ extra ].compact)
      [ locked, Pharmacy::Ledger.lock_location!(location.id) ]
    end

    # O FEFO relido sob a trava; só vale lote que está entre os travados. -> StockLot | nil
    def first_with_balance(item, location, quantity, today, locked, except: nil)
      fresh = Fefo.lots(catalog_item_id: item.catalog_item_id, stock_unit: item.stock_unit, location: location, today: today)
      entry = fresh.find { |row| row.lot.id != except && locked.key?(row.lot.id) && row.balance >= quantity }
      entry && locked.fetch(entry.lot.id)
    end

    def shortfall(cause, location, quantity) = Result.ok(shortfall_cause: cause, location: location, quantity: quantity)

    def invalid
      Result.fail(:lot_invalid, details: { path: "stock_lot_id", problems: [ { path: "stock_lot_id", error: "lot_invalid" } ] })
    end

    private_class_method :fefo, :chosen, :lock, :first_with_balance, :shortfall, :invalid
  end
end
