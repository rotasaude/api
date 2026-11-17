# Baixa de estoque de UMA medida química do boletim (módulo 35a, ADR 0054;
# contrato §4; W-7): escolhe o lote — um só, sem dividir a quantidade, como o
# Urgency::DeductStock — ou a causa da falta. Não grava nada: quem grava é o
# VectorControl::ApplyStock, no savepoint { DeductStock; Ledger.record! }.
#
# Local: o `vector_control_settings.stock_location_id` (lido pelo chamador),
# do tipo vector_control e ATIVO até a trava; ausente, de outro tipo,
# inativo ou desativado até a trava (Ledger::Inactive) → no_location, sem local.
# Lote: o primeiro do FEFO (VectorControl::Fefo) com saldo ≥ quantidade,
# relido sob a trava. Sem ele, a causa (Q21, que substitui a leitura do W-7):
# no_lot só quando o local não tem lote NENHUM do produto (nenhum movimento do
# produto no local); havendo lote, insufficient_balance — lote zerado
# (inclusive pela corrida), vencido, bloqueado, fora do conjunto travado ou com
# saldo menor que a quantidade.
#
# Ordem de trava (a do Ledger, depois das travas da visita): LOTES → LOCAL. Os
# lotes já vêm travados pelo VectorControl::ApplyStock (`locked`, FOR UPDATE de
# todas as medidas numa chamada, antes do local e dos savepoints): aqui o local
# é só relido (FOR SHARE, já seguro) e o lote sai SÓ de `locked` — nunca se
# trava lote novo depois do local (cruzaria com a desativação do local, que
# trava lotes e depois o local FOR UPDATE, e o deadlock recusaria a visita). Um
# lote que ganhou saldo entre a trava e a baixa não é candidato desta visita e
# cai na mesma falta. Duas visitas que disputam a última carga leem o mesmo
# saldo no FEFO, mas só a primeira o acha depois da trava; a segunda vira falta.
module VectorControl
  module DeductStock
    module_function

    # `measure`: VectorInspectionMeasure com produto e `quantity` > 0;
    # `locked`: { lot_id => StockLot } já travados FOR UPDATE pelo chamador.
    # -> Result.ok(location:, lot:, quantity:) | Result.ok(shortfall_cause:, location:, quantity:)
    def call(measure:, location_id:, today:, locked:)
      quantity = measure.quantity
      location = location_id && StockLocation.find_by(id: location_id, kind: "vector_control", active: true)
      return shortfall("no_location", nil, quantity) unless location

      location = Pharmacy::Ledger.lock_location!(location.id)

      fresh = Fefo.lots(product_id: measure.vector_product_id, location: location, today: today).select { |entry| locked.key?(entry.lot.id) }
      entry = fresh.find { |row| row.balance >= quantity }
      return shortfall(missing_cause(measure, location), location, quantity) unless entry

      Result.ok(location: location, lot: locked.fetch(entry.lot.id), quantity: quantity)
    rescue Pharmacy::Ledger::Inactive
      shortfall("no_location", nil, quantity)
    end

    # Q21: algum lote do produto já esteve no local (movimento) → falta saldo.
    def missing_cause(measure, location)
      present = StockMovement.exists?(stock_location_id: location.id, vector_product_id: measure.vector_product_id)
      present ? "insufficient_balance" : "no_lot"
    end

    def shortfall(cause, location, quantity) = Result.ok(shortfall_cause: cause, location: location, quantity: quantity)
    private_class_method :missing_cause, :shortfall
  end
end
