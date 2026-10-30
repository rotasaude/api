# Decisão de um ajuste `pending` por OUTRO responsável (ADR 0045; plano do api,
# Desvio 7; contrato §6/H4). `decision` é "approve" ou "reject".
#
# Quem decide: `stock_keeper` ou `pharmacist` do local do ajuste (`missing_role`,
# 403) e diferente de quem pediu (`same_user`, 403). As duas recusas de papel vêm
# sozinhas, antes de qualquer validação. Rejeitar exige motivo de 10 a 500
# caracteres (`reason_required`, path `reason`); aprovar aceita motivo opcional
# (presente, tem de ter 10 a 500: `invalid_reason`).
#
# Aprovar aplica o DELTA GUARDADO (`stock_adjustments.quantity`) sobre o saldo
# ATUAL, sob a trava do lote: saldo atual + delta negativo → `insufficient_balance`
# (422, path `id`) e o ajuste continua `pending`. Ajuste que já não é `pending`
# (relido sob trava) → `not_pending` (409): quem decide duas vezes cai aqui.
#
# Ordem de travas (a do módulo, Pharmacy::Ledger): lote → local → ajuste.
#   1. lock_lots!([lote]) — FOR UPDATE antes do movimento (o FK pede FOR KEY SHARE);
#   2. lock_location! — FOR SHARE no local e na unidade;
#   3. o ajuste relido com FOR UPDATE: duas decisões concorrentes se esperam aqui.
#
# Eventos `stock_adjustment.approved` / `.rejected` só com ids (stock_adjustment_id,
# user_id). O motivo (texto livre) nunca sai em log, evento nem erro.
module Pharmacy
  module DecideAdjustment
    DECIDER_ROLES = %w[stock_keeper pharmacist].freeze
    DECISIONS = %w[approve reject].freeze

    module_function

    # -> Result.ok(adjustment:, movement:) (movement nil ao rejeitar) | fail(:missing_role) |
    # fail(:same_user) | fail(:not_pending) | fail(:location_inactive) |
    # fail(<erro>, details: { path:, problems: [ { path:, error: } ] })
    def call(adjustment:, decision:, reason:, by:, now: Time.current)
      raise ArgumentError, "unknown decision" unless DECISIONS.include?(decision)
      return Result.fail(:missing_role) unless Access.allowed?(user: by, location: adjustment.stock_location, roles: DECIDER_ROLES)
      return Result.fail(:same_user) if adjustment.requested_by_user_id == by.id

      clean, problems = validate_reason(decision, reason)
      return failure(problems) if problems.any?

      result = nil
      StockAdjustment.transaction(requires_new: true) do
        result = write(adjustment, decision, clean, by, now)
        raise ActiveRecord::Rollback if result.failure?
      end
      result
    end

    def write(adjustment, decision, reason, by, now)
      lot = Ledger.lock_lots!([ adjustment.stock_lot_id ]).fetch(adjustment.stock_lot_id)
      location = Ledger.lock_location!(adjustment.stock_location_id)
      locked = StockAdjustment.lock("FOR UPDATE").find(adjustment.id)
      return Result.fail(:not_pending) unless locked.status == "pending"

      movement = decision == "approve" ? Ledger.record!(location: location, lot: lot, kind: "adjustment", quantity: locked.quantity, by: by,
                                                        document: locked, reason: locked.reason, at: now) : nil
      locked.update!(status: decision == "approve" ? "approved" : "rejected", decided_by_user: by, decided_at: now, decision_reason: reason)
      DomainEvents.publish("stock_adjustment.#{decision == 'approve' ? 'approved' : 'rejected'}", stock_adjustment_id: locked.id, user_id: by.id)
      Result.ok(adjustment: locked, movement: movement)
    rescue Ledger::Inactive
      Result.fail(:location_inactive)
    rescue Ledger::Insufficient
      failure([ problem("id", :insufficient_balance) ])
    end

    # -> [ motivo aparado | nil, [ problem ] ]
    def validate_reason(decision, reason)
      clean = reason.is_a?(String) ? reason.strip : nil
      return [ clean, [] ] if clean && Catalog::REASON.cover?(clean.length)
      return [ nil, [ problem("reason", :reason_required) ] ] if decision == "reject"
      return [ nil, [] ] if reason.nil?

      [ nil, [ problem("reason", :invalid_reason) ] ]
    end

    def problem(path, error) = { path: path, error: error.to_s }

    def failure(problems)
      first = problems.first
      Result.fail(first[:error], details: { path: first[:path], problems: problems })
    end

    private_class_method :write, :validate_reason, :problem, :failure
  end
end
