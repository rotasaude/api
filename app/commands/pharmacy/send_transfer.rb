# Envio de transferência do almoxarifado central para uma farmácia de unidade
# (ADR 0045; plano do api, Desvio 6). Enviar tira do central (um `transfer_out`
# por lote) e deixa o item "em trânsito": itens de transferência `sent`, sem
# movimento no destino (o destino só ganha saldo no recebimento).
#
# `items` é a lista de `{ "lot_id", "quantity" }` com chaves String (é o que o
# controlador entrega): `lot_id` uuid de lote existente, sem repetição
# (`invalid_items`, path `items[i].lot_id`); `quantity` String positiva do papel
# (`invalid_quantity`, path `items[i].quantity`). `from` precisa ser o central
# (senão `invalid_request`, path `from`); `to`, uma farmácia de unidade
# (`invalid_request`, path `to_location_id`, junto das recusas das linhas);
# lote vencido (`expires_on` antes de hoje na cidade; o dia da validade ainda
# vale) → `lot_expired`, path `items[i].lot_id`. Todo 422 traz `problems`.
#
# Todas as recusas voltam de uma vez: `error`/`path` do primeiro e `problems:
# [ { path, error } ]` com todas (H8/H12), inclusive `insufficient_balance`,
# apurado sob trava. Quando alguma linha é recusada antes da trava, o saldo das
# linhas válidas é lido (sem trava) só para dizer as recusas de saldo juntas; o
# veredito de saldo da escrita é o relido sob trava. Nada é gravado se houver
# recusa.
#
# Ordem de travas (a do módulo, veja Pharmacy::Ledger): lotes → local → documento.
#   1. lock_lots! — FOR UPDATE em TODOS os lotes da transferência, em ordem de
#      id, ANTES de inserir qualquer movimento E antes de inserir os itens
#      (stock_transfer_items.stock_lot_id pede FOR KEY SHARE no lote);
#   2. lock_location! (FOR SHARE) no central e depois na unidade, nessa ordem
#      (central é sempre a origem): fecha a corrida com a desativação do local
#      (SaveLocation lê `pending_work?` sob FOR UPDATE do local);
#   3. StockTransfer `sent` → itens → `transfer_out` por lote.
#
# Evento `stock_transfer.sent` só com ids (stock_transfer_id, user_id).
module Pharmacy
  module SendTransfer
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    # Linha já validada.
    Row = Struct.new(:index, :lot, :quantity, keyword_init: true)

    # Local inativo ou sumido sob a trava → LocationInactive com o path.
    class LocationInactive < StandardError
      attr_reader :path

      def initialize(path)
        @path = path
        super("location inactive")
      end
    end

    module_function

    # `to` nil (destino que o corpo não nomeou ou que não existe) entra como
    # problema `to_location_id`, junto das linhas.
    #
    # -> Result.ok(transfer:, items:, movements:) | fail(:location_inactive, details: { path: }) |
    # fail(<primeiro erro>, details: { path:, problems: [ { path:, error: } ] })
    def call(from:, to:, items:, by:, now: Time.current)
      return failure([ problem("from", :invalid_request) ]) unless from.central?

      problems = []
      problems << problem("to_location_id", :invalid_request) unless to&.unit?
      return Result.fail(:location_inactive, details: { path: "from" }) unless from.active
      return Result.fail(:location_inactive, details: { path: "to_location_id" }) if to&.unit? && !to.active

      unless items.is_a?(Array) && items.size.between?(1, Catalog::MAX_TRANSFER_ITEMS)
        problems << problem("items", :invalid_request)
        return failure(problems)
      end

      rows, row_problems = validate_rows(items, now.in_time_zone.to_date)
      problems += merge_by_line(row_problems, problems.any? || row_problems.any? ? balance_problems(from, rows) : [])
      return failure(problems) if problems.any?

      persist(from: from, to: to, rows: rows, by: by, now: now)
    end

    def persist(from:, to:, rows:, by:, now:)
      result = nil
      StockTransfer.transaction(requires_new: true) do
        result = write(from: from, to: to, rows: rows, by: by, now: now)
        raise ActiveRecord::Rollback if result.failure?
      end
      result
    end

    def write(from:, to:, rows:, by:, now:)
      lots = Ledger.lock_lots!(rows.map { |row| row.lot.id })
      lock_location(from, "from")
      lock_location(to, "to_location_id")

      short = short_problems(from, rows)
      return failure(short) if short.any?

      transfer = StockTransfer.create!(from_location: from, to_location: to, sent_by_user: by, status: "sent", sent_at: now, created_at: now)
      items = rows.map { |row| StockTransferItem.create!(stock_transfer: transfer, stock_lot: lots.fetch(row.lot.id), quantity_sent: row.quantity) }
      movements = rows.map do |row|
        Ledger.record!(location: from, lot: lots.fetch(row.lot.id), kind: "transfer_out", quantity: row.quantity, by: by, document: transfer, at: now)
      end
      DomainEvents.publish("stock_transfer.sent", stock_transfer_id: transfer.id, user_id: by.id)
      Result.ok(transfer: transfer, items: items, movements: movements)
    rescue Ledger::Insufficient => e
      # O trigger do banco, o cinto: só com o livro fora da trava.
      row = rows.find { |candidate| candidate.lot.id == e.lot_id } or raise KeyError, "insufficient balance on a lot outside the transfer"
      failure([ problem("items[#{row.index}].quantity", :insufficient_balance) ])
    rescue LocationInactive => e
      Result.fail(:location_inactive, details: { path: e.path })
    end

    # ---- validação (sem trava) ---------------------------------------------

    # -> [ [ Row ], [ problem ] ]. As linhas só valem sem problema algum.
    def validate_rows(items, today)
      candidates = items.filter_map { |raw| raw["lot_id"] if raw.is_a?(Hash) && raw["lot_id"].is_a?(String) && raw["lot_id"].match?(UUID) }
      lots = StockLot.where(id: candidates.uniq).index_by(&:id)
      seen = Set.new
      rows = []
      problems = []
      items.each_with_index do |raw, index|
        next problems << problem("items[#{index}]", :invalid_request) unless raw.is_a?(Hash)

        row, found = validate_row(raw, index, lots, seen, today)
        problems.concat(found)
        rows << row if row
      end
      [ rows, problems ]
    end

    def validate_row(raw, index, lots, seen, today)
      prefix = "items[#{index}]"
      problems = []
      lot = raw["lot_id"].is_a?(String) ? lots[raw["lot_id"]] : nil
      if lot.nil? || !seen.add?(lot.id)
        problems << problem("#{prefix}.lot_id", :invalid_items)
        lot = nil
      elsif lot.expires_on < today
        # O dia da validade ainda vale; o lote imutável não precisa de trava.
        problems << problem("#{prefix}.lot_id", :lot_expired)
        lot = nil
      end
      quantity = Quantity.parse(raw["quantity"])
      problems << problem("#{prefix}.quantity", :invalid_quantity) unless quantity
      return [ nil, problems ] if problems.any?

      [ Row.new(index: index, lot: lot, quantity: quantity), [] ]
    end

    # Saldo lido sem trava, só das linhas válidas: serve para dizer as recusas
    # de saldo junto das outras. -> [ problem ]
    def balance_problems(from, rows)
      return [] if rows.empty?

      balances = Ledger.balances(location_id: from.id, lot_ids: rows.map { |row| row.lot.id })
      rows.select { |row| balances.fetch(row.lot.id) < row.quantity }.map { |row| problem("items[#{row.index}].quantity", :insufficient_balance) }
    end

    # Recusas na ordem das linhas, sem repetir path + erro.
    def merge_by_line(row_problems, extra)
      (row_problems + extra).uniq.each_with_index.sort_by { |found, position| [ found[:path][/\Aitems\[(\d+)\]/, 1].to_i, position ] }.map(&:first)
    end

    # ---- sob trava ---------------------------------------------------------

    def lock_location(location, path)
      Ledger.lock_location!(location.id)
    rescue Ledger::Inactive
      raise LocationInactive, path
    end

    # Saldo relido com os lotes travados. -> [ problem ]
    def short_problems(from, rows)
      balances = Ledger.balances(location_id: from.id, lot_ids: rows.map { |row| row.lot.id })
      rows.select { |row| balances.fetch(row.lot.id) < row.quantity }.map { |row| problem("items[#{row.index}].quantity", :insufficient_balance) }
    end

    # ---- resultado ---------------------------------------------------------

    def problem(path, error) = { path: path, error: error.to_s }

    def failure(problems)
      first = problems.first
      Result.fail(first[:error], details: { path: first[:path], problems: problems })
    end

    private_class_method :persist, :write, :validate_rows, :validate_row, :balance_problems, :merge_by_line, :lock_location, :short_problems,
                         :problem, :failure
  end
end
