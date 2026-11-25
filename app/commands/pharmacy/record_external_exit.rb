# Saída externa do estoque (módulo 27b, Task 9; contrato §4; Q8, Q16): devolução
# ao fornecedor, remanejamento a outro ente, doação ou empréstimo. Tira do local
# (um `external_exit` por lote), nunca grava o lote nem o destino no estoque
# de ninguém. Não exige o `bnafar`.
#
# `attrs` (chaves String): `exit_type` (Bnafar::Catalog::EXTERNAL_EXIT_TYPES),
# `destination_kind` (`cnes` | `cnpj`), `destination_code` (CNES de 7 dígitos ou
# CNPJ com dígito verificador, alfanumérico; gravado só com os 14 caracteres),
# `reason` (10..500) e `items` (1..MAX_TRANSFER_ITEMS de `{ "lot_id", "quantity" }`).
# Quantidade inteira (JSON inteiro ou String de dígitos), 1..99999, na unidade de
# movimento do lote; na vacina só em múltiplo do frasco (a regra é de
# Bnafar::Units.to_bnafar: nil → `invalid_quantity`). O lote precisa ser do domínio
# do local (`item_not_allowed_here`, path `items[i]`) e não se repete
# (`invalid_items`).
#
# Lote bloqueado por excursão de temperatura → `lot_blocked` (path `items[i].lot_id`), em
# todo tipo de saída, conferido antes da trava e de novo sob ela. Lote vencido →
# `lot_expired` (mesmo path) em S-TR, S-D e S-E; a devolução ao fornecedor (S-DF) o aceita (Q29).
#
# Todas as recusas voltam de uma vez: `error`/`path` do primeiro e `problems:
# [ { path, error } ]` com todas, inclusive `insufficient_balance` (apurado sob
# trava). Nada é gravado se houver recusa.
#
# Ordem de travas (a do módulo, veja Pharmacy::Ledger): lotes → local → saída.
# Evento `stock_external_exit.recorded` só com ids (stock_external_exit_id, user_id).
module Pharmacy
  module RecordExternalExit
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    DIGITS = /\A\d{1,5}\z/
    MAX_ITEM_QUANTITY = 99_999

    # Linha já validada.
    Row = Struct.new(:index, :lot, :quantity, keyword_init: true)

    module_function

    # -> Result.ok(exit:, items:, movements:) | fail(:location_inactive, details: { path: }) |
    # fail(<primeiro erro>, details: { path:, problems: [ { path:, error: } ] })
    def call(location:, attrs:, by:, now: Time.current)
      return failure([ problem("attrs", :invalid_request) ]) unless attrs.is_a?(Hash)
      return Result.fail(:location_inactive, details: { path: "location_id" }) unless location.active

      problems, header = header(attrs)
      items = attrs["items"]
      unless items.is_a?(Array) && items.size.between?(1, Catalog::MAX_TRANSFER_ITEMS)
        return failure(problems + [ problem("items", :invalid_request) ])
      end

      expiry_refused = header[:exit_type] != "S-DF" # Q29: só a devolução ao fornecedor aceita lote vencido
      rows, row_problems = validate_rows(items, location, now.in_time_zone.to_date, expiry_refused)
      problems += row_problems + short_problems(location, rows)
      return failure(problems) if problems.any?

      persist(location: location, header: header, rows: rows, by: by, now: now)
    end

    # -> [ [ problem ], { exit_type:, destination_kind:, destination_code:, reason: } ]
    def header(attrs)
      problems = []
      type = attrs["exit_type"]
      problems << problem("exit_type", :invalid_request) unless ::Bnafar::Catalog::EXTERNAL_EXIT_TYPES.include?(type)
      kind = attrs["destination_kind"]
      problems << problem("destination_kind", :invalid_request) unless ::Bnafar::Catalog::DESTINATION_KINDS.include?(kind)
      code = destination_code(kind, attrs["destination_code"], problems)
      reason = attrs["reason"]
      problems << problem("reason", :invalid_request) unless reason.is_a?(String) && Catalog::REASON.cover?(reason.strip.length)
      [ problems, { exit_type: type, destination_kind: kind, destination_code: code, reason: reason.is_a?(String) ? reason.strip : nil } ]
    end

    # CNES: 7 dígitos. CNPJ: com dígito verificador (normalizado para os 14 caracteres).
    def destination_code(kind, raw, problems)
      return nil unless ::Bnafar::Catalog::DESTINATION_KINDS.include?(kind)

      if kind == "cnes"
        return raw if raw.is_a?(String) && raw.match?(::Bnafar::Catalog::CNES)

        problems << problem("destination_code", :invalid_request)
      else
        cnpj = Cnpj.normalize(raw)
        return cnpj if cnpj

        problems << problem("destination_code", :invalid_cnpj)
      end
      nil
    end

    # -> [ [ Row ], [ problem ] ]. As linhas só valem sem problema algum.
    def validate_rows(items, location, today, expiry_refused)
      candidates = items.filter_map { |raw| raw["lot_id"] if raw.is_a?(Hash) && raw["lot_id"].is_a?(String) && raw["lot_id"].match?(UUID) }
      lots = StockLot.where(id: candidates.uniq).index_by(&:id)
      blocked = blocked_lot_ids(location, lots.keys)
      seen = Set.new
      rows = []
      problems = []
      items.each_with_index do |raw, index|
        next problems << problem("items[#{index}]", :invalid_request) unless raw.is_a?(Hash)

        row, found = validate_row(raw, index, lots, seen, location, today: today, expiry_refused: expiry_refused, blocked: blocked)
        problems.concat(found)
        rows << row if row
      end
      [ rows, problems ]
    end

    def validate_row(raw, index, lots, seen, location, today:, expiry_refused:, blocked:)
      prefix = "items[#{index}]"
      problems = []
      lot = raw["lot_id"].is_a?(String) ? lots[raw["lot_id"]] : nil
      if lot.nil? || !seen.add?(lot.id)
        problems << problem("#{prefix}.lot_id", :invalid_items)
        lot = nil
      elsif !Stock::Domain.allows?(location, lot)
        problems << problem(prefix, :item_not_allowed_here)
        lot = nil
      elsif expiry_refused && lot.expires_on < today
        # O dia da validade ainda vale (como na transferência).
        problems << problem("#{prefix}.lot_id", :lot_expired)
        lot = nil
      elsif blocked.include?(lot.id)
        problems << problem("#{prefix}.lot_id", :lot_blocked)
        lot = nil
      end
      quantity = parse_quantity(raw["quantity"])
      # A regra do frasco é da BNAFAR (Units): nunca repetida aqui.
      quantity = nil if quantity && lot && ::Bnafar::Units.to_bnafar(lot, quantity).nil?
      problems << problem("#{prefix}.quantity", :invalid_quantity) unless quantity
      return [ nil, problems ] if problems.any?

      [ Row.new(index: index, lot: lot, quantity: quantity), [] ]
    end

    # JSON inteiro ou String de dígitos; nada de decimal, sinal ou zero. -> Integer | nil
    def parse_quantity(raw)
      value = raw.is_a?(Integer) ? raw : (raw.is_a?(String) && raw.match?(DIGITS) ? raw.to_i : nil)
      value&.between?(1, MAX_ITEM_QUANTITY) ? value : nil
    end

    # Saldo lido (sem trava ou com ela) das linhas válidas. -> [ problem ]
    def short_problems(location, rows)
      return [] if rows.empty?

      balances = Ledger.balances(location_id: location.id, lot_ids: rows.map { |row| row.lot.id })
      rows.select { |row| balances.fetch(row.lot.id) < row.quantity }.map { |row| problem("items[#{row.index}].quantity", :insufficient_balance) }
    end

    # Lotes com bloqueio aberto (excursão de temperatura) no local. -> Set
    def blocked_lot_ids(location, lot_ids)
      return Set.new if lot_ids.empty?

      StockLotBlock.open_blocks.where(stock_location_id: location.id, stock_lot_id: lot_ids).pluck(:stock_lot_id).to_set
    end

    # Bloqueio relido com os lotes travados. -> [ problem ]
    def blocked_problems(location, rows)
      blocked = blocked_lot_ids(location, rows.map { |row| row.lot.id })
      rows.select { |row| blocked.include?(row.lot.id) }.map { |row| problem("items[#{row.index}].lot_id", :lot_blocked) }
    end

    def persist(location:, header:, rows:, by:, now:)
      result = nil
      StockExternalExit.transaction(requires_new: true) do
        result = write(location: location, header: header, rows: rows, by: by, now: now)
        raise ActiveRecord::Rollback if result.failure?
      end
      result
    end

    def write(location:, header:, rows:, by:, now:)
      lots = Ledger.lock_lots!(rows.map { |row| row.lot.id })
      begin
        Ledger.lock_location!(location.id)
      rescue Ledger::Inactive
        return Result.fail(:location_inactive, details: { path: "location_id" })
      end

      blocked = blocked_problems(location, rows)
      return failure(blocked) if blocked.any?

      short = short_problems(location, rows)
      return failure(short) if short.any?

      external = StockExternalExit.create!(header.merge(stock_location: location, recorded_by_user: by, recorded_at: now, created_at: now))
      items = rows.map { |row| StockExternalExitItem.create!(stock_external_exit: external, stock_lot: lots.fetch(row.lot.id), quantity: row.quantity, created_at: now) }
      movements = rows.map do |row|
        Ledger.record!(location: location, lot: lots.fetch(row.lot.id), kind: "external_exit", quantity: row.quantity, by: by, document: external, at: now)
      end
      DomainEvents.publish("stock_external_exit.recorded", stock_external_exit_id: external.id, user_id: by.id)
      Result.ok(exit: external, items: items, movements: movements)
    rescue Ledger::Insufficient => e
      # O trigger do banco, o cinto: só com o livro fora da trava.
      row = rows.find { |candidate| candidate.lot.id == e.lot_id } or raise KeyError, "insufficient balance on a lot outside the exit"
      failure([ problem("items[#{row.index}].quantity", :insufficient_balance) ])
    end

    def problem(path, error) = { path: path, error: error.to_s }

    def failure(problems)
      first = problems.first
      Result.fail(first[:error], details: { path: first[:path], problems: problems })
    end

    private_class_method :header, :destination_code, :validate_rows, :validate_row, :parse_quantity, :short_problems, :blocked_lot_ids, :blocked_problems, :persist, :write, :problem, :failure
  end
end
