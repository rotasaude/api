# Baixa do boletim no razão do 27a (módulo 35a, ADR 0054; contrato §4; Review
# Focus 2): para cada medida química (com produto), um savepoint
# { DeductStock; Ledger.record!(kind: "vector_application", document: medida) }.
# Sem local, sem lote ou sem saldo (inclusive a recusa do Ledger ou do trigger,
# Ledger::Insufficient → insufficient_balance), só o savepoint volta e a medida
# ganha a falta `vector_stock_shortfalls` com `vector_stock.shortfall_recorded`
# (só o id). NUNCA recusa a visita (invariante do ADR 0054) e nunca deixa o
# saldo negativo.
#
# Só o VectorControl::RecordInspection chama, na transação da visita, depois
# das medidas. Ordem de trava: os produtos já estão FOR SHARE (facts!); aqui
# os LOTES de todas as medidas numa só chamada (Ledger.lock_lots!, em ordem de
# id) → o LOCAL (FOR SHARE), antes dos savepoints: a trava fica com a visita
# mesmo quando um savepoint volta, e duas visitas (ou a visita e uma entrada)
# nunca pedem lotes em ordem cruzada. Cada DeductStock relê o saldo sob a trava.
module VectorControl
  module ApplyStock
    SHORTFALL_EVENT = "vector_stock.shortfall_recorded".freeze

    module_function

    # -> [Result.ok(movement:) | Result.ok(shortfall:)], um por medida química.
    def call(inspection:, by:, today:)
      measures = VectorInspectionMeasure.where(vector_inspection_id: inspection.id).where.not(vector_product_id: nil)
                                        .order(:vector_product_id, :method).to_a
      return [] if measures.empty?

      location_id = VectorControlSetting.find_by(id: 1)&.stock_location_id
      locked = lock!(measures, location_id, today)
      measures.map { |measure| apply(measure, location_id, locked, by, today) }
    end

    # -> { lot_id => StockLot } travados (o único conjunto de onde a baixa escolhe).
    def lock!(measures, location_id, today)
      location = location_id && StockLocation.find_by(id: location_id, kind: "vector_control", active: true)
      return {} unless location

      lot_ids = measures.map(&:vector_product_id).uniq.flat_map do |product_id|
        Fefo.lots(product_id: product_id, location: location, today: today).map { |entry| entry.lot.id }
      end
      locked = Pharmacy::Ledger.lock_lots!(lot_ids)
      Pharmacy::Ledger.lock_location!(location.id)
      locked
    rescue Pharmacy::Ledger::Inactive
      {} # a DeductStock vê o local inativo e grava no_location
    end

    def apply(measure, location_id, locked, by, today)
      location = nil
      outcome = VectorInspectionMeasure.transaction(requires_new: true) do
        result = DeductStock.call(measure: measure, location_id: location_id, today: today, locked: locked)
        location = result.payload[:location]
        next result if result.payload[:shortfall_cause]

        Pharmacy::Ledger.record!(location: location, lot: result.payload.fetch(:lot), kind: "vector_application",
                                 quantity: result.payload.fetch(:quantity), by: by, document: measure)
      end
      return shortfall!(measure, outcome.payload.fetch(:shortfall_cause), location) if outcome.is_a?(Result)

      Result.ok(movement: outcome)
    rescue Pharmacy::Ledger::Insufficient
      shortfall!(measure, "insufficient_balance", location)
    end

    def shortfall!(measure, cause, location)
      shortfall = VectorStockShortfall.create!(vector_inspection_measure: measure, vector_product_id: measure.vector_product_id,
                                               stock_location: (location unless cause == "no_location"), quantity: measure.quantity,
                                               cause: cause)
      DomainEvents.publish(SHORTFALL_EVENT, vector_stock_shortfall_id: shortfall.id)
      Result.ok(shortfall: shortfall)
    end

    private_class_method :lock!, :apply, :shortfall!
  end
end
