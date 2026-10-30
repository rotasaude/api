# Extrato de um lote num local (ADR 0045; contrato §4 e H12): os movimentos do
# lote NAQUELE local, mais novos primeiro, por (recorded_at, id) decrescente.
# A ordem é a da data DO MOVIMENTO, não a da gravação: entrada de lote já
# vencido ou conferência retroativa nascem com `recorded_at` no passado e
# ficam no lugar certo do extrato. Movimentos do mesmo instante (o recebimento
# grava `transfer_in` e `loss` com a mesma data) desempatam pela gravação
# (`created_at`) e, por último, pelo id: a ordem é a mesma a cada leitura.
#
# Cada movimento: `{ id, kind, quantity (com sinal), reason|null, at, by: { name },
# document: { type: "entry"|"transfer"|"dispensation"|"adjustment", id, number|null } }`.
# O motivo (texto livre, cifrado) vai só no corpo. A dispensação aparece SÓ com
# o id da dispensação: nunca paciente, receita ou medicamento do paciente.
# `by.name` é o do perfil profissional (o almoxarife não tem perfil: `null`).
#
# `before` é o cursor JÁ decodificado e validado:
# [recorded_at iso8601(6), created_at iso8601(6), id].
module Pharmacy
  module Statement
    PRELOAD = [ { recorded_by_user: :professional }, :stock_entry, :dispensation_item ].freeze

    module_function

    # -> { lot: <lot>, balance, movements: [ … ], next_before }
    def call(location:, lot:, limit:, before: nil)
      scope = StockMovement.where(stock_location_id: location.id, stock_lot_id: lot.id)
      if before
        scope = scope.where("(stock_movements.recorded_at, stock_movements.created_at, stock_movements.id) < (?, ?, ?)",
                            Time.iso8601(before[0]), Time.iso8601(before[1]), before[2])
      end
      rows = scope.includes(*PRELOAD).order(recorded_at: :desc, created_at: :desc, id: :desc).limit(limit + 1).to_a
      page = rows.first(limit)
      { lot: Json.lot(lot, catalog: Json.catalog_for([ lot.catalog_item_id ])),
        balance: Quantity.dump(Ledger.balance(location_id: location.id, lot_id: lot.id)),
        movements: page.map { |movement| present(movement) },
        next_before: rows.size > limit ? cursor_for(page.last) : nil }
    end

    def cursor_for(movement)
      Cursor.encode([ movement.recorded_at.utc.iso8601(6), movement.created_at.utc.iso8601(6), movement.id ])
    end
    private_class_method :cursor_for

    def present(movement)
      { id: movement.id, kind: movement.kind, quantity: Quantity.dump(movement.quantity), reason: movement.reason,
        at: movement.recorded_at.iso8601, by: { name: movement.recorded_by_user.professional&.professional_name },
        document: document(movement) }
    end
    private_class_method :present

    # Exatamente um dos quatro documentos (CHECK do banco).
    def document(movement)
      if movement.stock_entry_id
        { type: "entry", id: movement.stock_entry_id, number: movement.stock_entry.document_number }
      elsif movement.stock_transfer_id
        { type: "transfer", id: movement.stock_transfer_id, number: nil }
      elsif movement.dispensation_item_id
        { type: "dispensation", id: movement.dispensation_item.dispensation_id, number: nil }
      else
        { type: "adjustment", id: movement.stock_adjustment_id, number: nil }
      end
    end
    private_class_method :document
  end
end
