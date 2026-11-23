# Baixa da dose antirrábica e da coleira no razão do 27a (módulo 35b, ADR
# 0054; contrato §3, Q17), no molde do VectorControl::ApplyStock do 35a: 1 un
# do local `vector_control_settings.stock_location_id` pelo FEFO do 35a
# (VectorControl::Fefo; o lote não é escolhido), num savepoint
# { VectorControl::DeductStock; Ledger.record!(kind:, document:) }. Sem local,
# sem lote ou sem saldo (inclusive a recusa do Ledger ou do trigger,
# Ledger::Insufficient → insufficient_balance), só o savepoint volta e o
# documento ganha a falta `vector_stock_shortfalls` com `source` (`vaccination`
# ou `collar`), a referência e `occurred_on` (o dia da dose ou da colocação),
# e `vector_stock.shortfall_recorded` só com o id. NUNCA recusa o registro.
#
# Chamado pelo comando dono do documento, na transação dele, depois de gravar
# o documento. Ordem de trava: os LOTES do produto (Ledger.lock_lots!, em
# ordem de id) → o LOCAL (FOR SHARE), antes do savepoint; a DeductStock relê o
# saldo sob a trava e só escolhe entre os lotes travados.
#
# `reverse!` (anulação da dose): o `animal_vaccination` ganha um
# `animal_vaccination_reversal` (positivo) no mesmo lote e local, uma vez;
# a falta aberta da dose é conciliada pelo sistema (`reconciled_at`, sem
# usuário nem nota; W-6 do 35a). Trava lotes → local → falta. O local
# desativado depois da baixa recebe o estorno assim mesmo.
module Zoonoses
  module ApplyStock
    SHORTFALL_EVENT = VectorControl::ApplyStock::SHORTFALL_EVENT
    QUANTITY = BigDecimal("1")
    REVERSAL = "animal_vaccination_reversal".freeze

    module_function

    # `document`: RabiesVaccination | Collar já gravado; `kind`:
    # animal_vaccination | collar_placement.
    # -> Result.ok(movement:) | Result.ok(shortfall:)
    def call(document:, product_id:, kind:, by:, today:)
      raise ArgumentError, "unknown zoonoses stock document" unless document.is_a?(RabiesVaccination) || document.is_a?(Collar)

      location_id = VectorControlSetting.find_by(id: 1)&.stock_location_id
      locked = lock!(product_id, location_id, today)
      location = nil
      outcome = StockMovement.transaction(requires_new: true) do
        result = VectorControl::DeductStock.call(product_id: product_id, quantity: QUANTITY, location_id: location_id,
                                                 today: today, locked: locked)
        location = result.payload[:location]
        next result if result.payload[:shortfall_cause]

        Pharmacy::Ledger.record!(location: location, lot: result.payload.fetch(:lot), kind: kind,
                                 quantity: result.payload.fetch(:quantity), by: by, document: document)
      end
      return shortfall!(document, product_id, outcome.payload.fetch(:shortfall_cause), location) if outcome.is_a?(Result)

      Result.ok(movement: outcome)
    rescue Pharmacy::Ledger::Insufficient
      shortfall!(document, product_id, "insufficient_balance", location)
    end

    # -> StockMovement (o estorno) | nil (sem baixa a estornar: falta ou já estornada)
    def reverse!(vaccination:, by:, now: Time.current)
      applied = StockMovement.where(rabies_vaccination_id: vaccination.id, kind: "animal_vaccination").order(:id).first
      reversed = StockMovement.where(rabies_vaccination_id: vaccination.id, kind: REVERSAL).exists?
      movement = nil
      if applied && !reversed
        lot = Pharmacy::Ledger.lock_lots!([ applied.stock_lot_id ]).fetch(applied.stock_lot_id)
        location = StockLocation.lock("FOR SHARE").find(applied.stock_location_id)
        movement = Pharmacy::Ledger.record!(location: location, lot: lot, kind: REVERSAL, quantity: -applied.quantity, by: by,
                                            document: vaccination, at: now)
      end
      VectorStockShortfall.where(rabies_vaccination_id: vaccination.id, reconciled_at: nil).lock.each do |shortfall|
        shortfall.update!(reconciled_at: now, version: shortfall.version + 1)
      end
      movement
    end

    # -> { lot_id => StockLot } travados (o único conjunto de onde a baixa escolhe).
    def lock!(product_id, location_id, today)
      location = location_id && StockLocation.find_by(id: location_id, kind: "vector_control", active: true)
      return {} unless location

      lot_ids = VectorControl::Fefo.lots(product_id: product_id, location: location, today: today).map { |entry| entry.lot.id }
      locked = Pharmacy::Ledger.lock_lots!(lot_ids)
      Pharmacy::Ledger.lock_location!(location.id)
      locked
    rescue Pharmacy::Ledger::Inactive
      {} # a DeductStock vê o local inativo e grava no_location
    end

    def shortfall!(document, product_id, cause, location)
      reference = document.is_a?(Collar) ? { source: "collar", collar: document, occurred_on: document.placed_on } :
                                           { source: "vaccination", rabies_vaccination: document, occurred_on: document.vaccinated_on }
      shortfall = VectorStockShortfall.create!(**reference, vector_product_id: product_id, quantity: QUANTITY, cause: cause,
                                               stock_location: (location unless cause == "no_location"))
      DomainEvents.publish(SHORTFALL_EVENT, vector_stock_shortfall_id: shortfall.id)
      Result.ok(shortfall: shortfall)
    end

    private_class_method :lock!, :shortfall!
  end
end
