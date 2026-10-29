# Recebimento de uma transferência enviada (ADR 0045; plano do api, Desvio 6;
# H5). O destino confere lote a lote: `quantity_received` de 0 até o enviado.
# Grava um `transfer_in` do ENVIADO no destino e, havendo diferença, um `loss`
# da diferença no destino com o motivo (10..500): o extrato do destino mostra as
# duas linhas. Sem diferença em nenhum lote → `received`; com → `received_with_
# difference`.
#
# `items` é a lista de `{ "lot_id", "quantity_received", "reason"? }` com chaves
# String: TODOS os lotes da transferência, uma vez cada (`invalid_items`; lote
# faltando → path `items`, lote alheio ou repetido → path `items[i].lot_id`).
# `quantity_received` String do papel, `"0"` vale (`invalid_quantity`, path
# `items[i].quantity_received`, também quando passa do enviado). Diferença sem
# motivo válido → `reason_required` (path `items[i].reason`); motivo onde não há
# diferença é ignorado (não é gravado).
#
# Todas as recusas voltam de uma vez (H8/H12): `error`/`path` do primeiro e
# `problems: [ { path, error } ]`. Transferência que já não está `sent` →
# `already_received` (409), sozinho. Nada é gravado se houver recusa.
#
# Ordem de travas (a do módulo): lotes → local → documento.
#   1. lock_lots! — FOR UPDATE nos lotes DA TRANSFERÊNCIA (ids ordenados) antes
#      de qualquer movimento (o FK pede FOR KEY SHARE no lote). Dois
#      recebimentos concorrentes da mesma transferência se esperam aqui;
#   2. lock_location! (FOR SHARE) no destino;
#   3. a transferência relida com FOR UPDATE: quem chegou depois vê o status
#      novo e termina em already_received.
#
# Evento `stock_transfer.received` só com ids e o booleano (stock_transfer_id,
# user_id, with_difference).
module Pharmacy
  module ReceiveTransfer
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    # Linha já validada: o item enviado, o recebido, a diferença e o motivo. O
    # motivo é texto livre: não sai em inspect, to_s, pretty_print nem as_json.
    Row = Struct.new(:index, :item, :received, :difference, :reason, keyword_init: true) do
      def inspect = "#<#{self.class.name} index=#{index}>"
      def to_s = inspect
      def pretty_print(pp) = pp.text(inspect)
      def as_json(*) = { "index" => index }
    end

    module_function

    # -> Result.ok(transfer:, with_difference:) | fail(:already_received) |
    # fail(:invalid_request, details: { path: }) | fail(:location_inactive) |
    # fail(<primeiro erro>, details: { path:, problems: [ { path:, error: } ] })
    def call(transfer:, items:, by:, now: Time.current)
      return Result.fail(:already_received) unless transfer.status == "sent"
      return Result.fail(:invalid_request, details: { path: "items" }) unless items.is_a?(Array) && items.size.between?(1, Catalog::MAX_TRANSFER_ITEMS)

      sent = transfer.items.includes(:stock_lot).to_a
      rows, problems = validate_rows(items, sent)
      return failure(problems) if problems.any?

      persist(transfer: transfer, sent: sent, rows: rows, by: by, now: now)
    end

    def persist(transfer:, sent:, rows:, by:, now:)
      result = nil
      StockTransfer.transaction(requires_new: true) do
        result = write(transfer: transfer, sent: sent, rows: rows, by: by, now: now)
        raise ActiveRecord::Rollback if result.failure?
      end
      result
    end

    def write(transfer:, sent:, rows:, by:, now:)
      lots = Ledger.lock_lots!(sent.map(&:stock_lot_id))
      to = Ledger.lock_location!(transfer.to_location_id)
      locked = StockTransfer.lock("FOR UPDATE").find(transfer.id)
      return Result.fail(:already_received) unless locked.status == "sent"

      rows.each { |row| receive_row(locked, to, lots.fetch(row.item.stock_lot_id), row, by, now) }
      with_difference = rows.any? { |row| row.difference.positive? }
      locked.update!(status: with_difference ? "received_with_difference" : "received", received_at: now, received_by_user: by)
      DomainEvents.publish("stock_transfer.received", stock_transfer_id: locked.id, user_id: by.id, with_difference: with_difference)
      Result.ok(transfer: locked, with_difference: with_difference)
    rescue Ledger::Inactive
      Result.fail(:location_inactive)
    rescue Ledger::Insufficient => e
      # Só com o livro fora da trava (o destino nunca fica abaixo do que entrou).
      row = rows.find { |candidate| candidate.item.stock_lot_id == e.lot_id }
      failure([ problem("items[#{row&.index.to_i}].quantity_received", :insufficient_balance) ])
    end

    def receive_row(transfer, to, lot, row, by, now)
      Ledger.record!(location: to, lot: lot, kind: "transfer_in", quantity: row.item.quantity_sent, by: by, document: transfer, at: now)
      if row.difference.positive?
        Ledger.record!(location: to, lot: lot, kind: "loss", quantity: row.difference, by: by, document: transfer, reason: row.reason, at: now)
      end
      row.item.update!(quantity_received: row.received, difference_reason: (row.reason if row.difference.positive?))
    end

    # ---- validação (sem banco) ---------------------------------------------

    # -> [ [ Row ], [ problem ] ]. As linhas só valem sem problema algum.
    def validate_rows(items, sent)
      by_lot = sent.index_by(&:stock_lot_id)
      seen = Set.new
      rows = []
      problems = []
      items.each_with_index do |raw, index|
        next problems << problem("items[#{index}]", :invalid_request) unless raw.is_a?(Hash)

        row, found = validate_row(raw, index, by_lot, seen)
        problems.concat(found)
        rows << row if row
      end
      # Faltou algum lote da transferência (os alheios e os repetidos já foram ditos).
      problems << problem("items", :invalid_items) if (by_lot.keys - seen.to_a).any?
      [ rows, problems ]
    end

    def validate_row(raw, index, by_lot, seen)
      prefix = "items[#{index}]"
      problems = []
      lot_id = raw["lot_id"]
      item = lot_id.is_a?(String) && lot_id.match?(UUID) ? by_lot[lot_id] : nil
      if item.nil? || !seen.add?(item.stock_lot_id)
        problems << problem("#{prefix}.lot_id", :invalid_items)
        item = nil
      end

      received = Quantity.parse(raw["quantity_received"], allow_zero: true)
      received = nil if received && item && received > item.quantity_sent
      problems << problem("#{prefix}.quantity_received", :invalid_quantity) unless received
      difference = received && item ? item.quantity_sent - received : nil

      reason = raw["reason"]
      reason = reason.strip if reason.is_a?(String)
      if difference&.positive? && !(reason.is_a?(String) && Catalog::REASON.cover?(reason.length))
        problems << problem("#{prefix}.reason", :reason_required)
      end
      return [ nil, problems ] if problems.any?

      [ Row.new(index: index, item: item, received: received, difference: difference, reason: reason), [] ]
    end

    # ---- resultado ---------------------------------------------------------

    def problem(path, error) = { path: path, error: error.to_s }

    def failure(problems)
      first = problems.first
      Result.fail(first[:error], details: { path: first[:path], problems: problems })
    end

    private_class_method :persist, :write, :receive_row, :validate_rows, :validate_row, :problem, :failure
  end
end
