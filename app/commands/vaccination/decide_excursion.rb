# Conduta da excursão de temperatura, lote a lote (ADR 0047; contrato §8; §15
# V14 = D9; Review Focus 4). Quem pode (room_lead da sala, stock_keeper da rede
# de frio) e o step-up são do controlador. Corpo `{ lots: [ { lot_id,
# decision: "use"|"discard", reason (10–500) } ] }`.
#
# - `use`: o bloqueio cai na hora (`released_at`, `decision: "use"`), sem perda.
# - `discard`: PASSA pelo Pharmacy::RequestAdjustment (`kind: "loss"`,
#   `loss_code: "temperature_excursion"`, quantidade = o saldo do lote no
#   local, `excursion:` libera só o `lot_blocked` desta excursão), com o limite
#   de aprovação do 27a. Aplicada → o bloqueio cai e os frascos abertos do lote
#   fecham (ExcursionRelease). `pending` → o lote segue bloqueado (dose e
#   frasco) até o DecideAdjustment aprovar; recusada, a conduta do lote pode
#   ser refeita. Sem saldo (só frasco aberto), não há ajuste: fecha os frascos
#   e solta.
#
# Todos os lotes à espera de conduta (bloqueio aberto sem perda pendente)
# precisam vir (`lots_missing`, path `lots`); lote fora dos bloqueios abertos
# da excursão → `lot_not_in_excursion`; lote com perda pendente →
# `adjustment_pending` (paths `lots[i].lot_id`). A excursão fecha (decided_at,
# decided_by) quando não resta bloqueio aberto; já fechada → `excursion_closed`
# (409). Tudo ou nada: uma recusa desfaz a conduta inteira.
#
# Ordem de travas (a do módulo): lotes da excursão → local → excursão →
# ajuste (RequestAdjustment) → frascos. O motivo nunca sai em log, evento ou erro.
module Vaccination
  module DecideExcursion
    LOSS_CODE = "temperature_excursion".freeze
    MAX_LINES = 200
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    Line = Struct.new(:lot_id, :decision, :reason, keyword_init: true) do
      def inspect = "#<#{self.class.name} lot_id=#{lot_id} decision=#{decision}>"
      def to_s = inspect
      def pretty_print(pp) = pp.text(inspect)
      def as_json(*) = { "lot_id" => lot_id, "decision" => decision }
    end

    module_function

    # -> Result.ok(excursion:, adjustments: [StockAdjustment]) | fail(:excursion_closed) |
    # fail(:location_inactive) | fail(<erro>, details: { path:, problems: })
    def call(excursion:, lots:, by:, settings:, now: Time.current)
      lines, problems = validate(lots)
      return failure(problems) if problems.any?

      result = nil
      ColdChainExcursion.transaction(requires_new: true) do
        result = write(excursion, lines, by, settings, now)
        raise ActiveRecord::Rollback if result.failure?
      end
      result
    end

    def write(excursion, lines, by, settings, now)
      stock_lots = Pharmacy::Ledger.lock_lots!(StockLotBlock.where(cold_chain_excursion_id: excursion.id).pluck(:stock_lot_id))
      location = Pharmacy::Ledger.lock_location!(excursion.stock_location_id)
      locked = ColdChainExcursion.lock("FOR UPDATE").find(excursion.id)
      return Result.fail(:excursion_closed) if locked.decided_at

      open = StockLotBlock.open_blocks.where(cold_chain_excursion_id: locked.id).includes(:stock_adjustment).index_by(&:stock_lot_id)
      pending = open.select { |_lot_id, block| block.stock_adjustment&.status == "pending" }.keys
      problems = lines.each_with_index.filter_map do |line, index|
        if !open.key?(line.lot_id) then problem("lots[#{index}].lot_id", :lot_not_in_excursion)
        elsif pending.include?(line.lot_id) then problem("lots[#{index}].lot_id", :adjustment_pending)
        end
      end
      return failure(problems) if problems.any?
      return failure([ problem("lots", :lots_missing) ]) unless (open.keys - pending - lines.map(&:lot_id)).empty?

      adjustments = []
      lines.each_with_index do |line, index|
        block = open.fetch(line.lot_id)
        if line.decision == "use"
          block.update!(released_at: now, decision: "use", decision_reason: line.reason, decided_by_user: by, stock_adjustment_id: nil)
          next
        end

        outcome = discard(block, location, stock_lots.fetch(line.lot_id), locked, line, by, settings, now)
        return prefixed(outcome, index) if outcome.failure?

        adjustments << outcome.payload[:adjustment] if outcome.payload[:adjustment]
      end
      ExcursionRelease.close_if_settled!(locked.id, by_id: by.id, now: now)
      Result.ok(excursion: locked.reload, adjustments: adjustments)
    rescue Pharmacy::Ledger::Inactive
      Result.fail(:location_inactive)
    end

    # -> Result.ok(adjustment: | nil) | a recusa do RequestAdjustment
    def discard(block, location, lot, excursion, line, by, settings, now)
      block.update!(decision_reason: line.reason, decided_by_user: by, stock_adjustment_id: nil)
      balance = Pharmacy::Ledger.balance(location_id: location.id, lot_id: lot.id)
      unless balance.positive?
        ExcursionRelease.discard!(block, now: now)
        return Result.ok(adjustment: nil)
      end

      result = Pharmacy::RequestAdjustment.call(location: location, lot: lot, kind: "loss", counted_quantity: nil,
                                                quantity: Pharmacy::Quantity.dump(balance), reason: line.reason, loss_code: LOSS_CODE,
                                                by: by, settings: settings, excursion: excursion, now: now)
      return result if result.failure?

      adjustment = result.payload.fetch(:adjustment)
      block.update!(stock_adjustment: adjustment)
      ExcursionRelease.discard!(block, now: now) if adjustment.status == "applied"
      Result.ok(adjustment: adjustment)
    end

    # -> [ [Line], [ problem ] ]
    def validate(lots)
      return [ [], [ problem("lots", :invalid_request) ] ] unless lots.is_a?(Array) && lots.size.between?(1, MAX_LINES)

      seen = Set.new
      problems = []
      lines = lots.each_with_index.map do |raw, index|
        raw = raw.is_a?(Hash) ? raw.stringify_keys : {}
        lot_id = raw["lot_id"]
        if !(lot_id.is_a?(String) && lot_id.match?(UUID)) || seen.include?(lot_id)
          problems << problem("lots[#{index}].lot_id", :invalid_request)
        end
        seen << lot_id
        decision = raw["decision"]
        problems << problem("lots[#{index}].decision", :invalid_request) unless Catalog::EXCURSION_DECISIONS.include?(decision)
        reason = raw["reason"].is_a?(String) ? raw["reason"].strip : nil
        problems << problem("lots[#{index}].reason", :invalid_reason) unless reason && Catalog::REASON.cover?(reason.length)
        Line.new(lot_id: lot_id, decision: decision, reason: reason)
      end
      [ lines, problems ]
    end

    # Recusa do RequestAdjustment com os paths sob `lots[i].`.
    def prefixed(result, index)
      problems = result.details[:problems] || [ { path: result.details[:path] || "lot_id", error: result.reason.to_s } ]
      failure(problems.map { |found| { path: "lots[#{index}].#{found[:path]}", error: found[:error].to_s } })
    end

    def problem(path, error) = { path: path, error: error.to_s }

    def failure(problems)
      first = problems.first
      Result.fail(first[:error], details: { path: first[:path], problems: problems })
    end

    private_class_method :write, :discard, :validate, :prefixed, :problem, :failure
  end
end
