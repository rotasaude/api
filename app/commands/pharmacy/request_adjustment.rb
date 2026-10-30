# Ajuste de contagem, perda ou vencimento de UM lote num local (ADR 0045; plano
# do api, Desvio 7; contrato H4). Quem pode (stock_keeper ou pharmacist do
# local) e o step-up são do controlador.
#
# - `adjustment`: `counted_quantity` é o SALDO contado (String, `"0"` vale, até
#   numeric(14,2)); `delta = contado - saldo`. `delta = 0` → `no_difference`;
#   |delta| > 99999.99 → `invalid_quantity` (o teto da coluna `quantity`).
#   `pending` ⇔ `saldo.zero? || |delta| * 100 > saldo * adjustment_approval_percent`
#   (saldo zero conta como acima; com o percentual em 0 todo ajuste é pending): sem
#   movimento até a aprovação. Senão `applied`, com um movimento `adjustment`
#   de sinal (o delta).
# - `loss` e `expiry`: `quantity` String positiva (até 99999.99), aplicadas na
#   hora (nunca vão a aprovação) com o movimento de saída. `loss` só com o lote
#   NÃO vencido (`lot_expired`); `expiry` só com o lote vencido
#   (`lot_not_expired`). O dia da validade ainda vale. Saldo menor que a
#   quantidade → `insufficient_balance`.
#
# `stock_adjustments.quantity` guarda o EFEITO no estoque, com sinal: o delta da
# contagem, ou a saída (negativa) de perda/vencimento (CHECK do banco).
#
# Todo 422 traz `problems` (H8/H12): `error`/`path` do primeiro e `[ { path, error } ]`
# com TODAS as recusas, inclusive as de saldo, na ordem dos campos: lot_id (id
# e estado de validade do lote), kind, counted_quantity, quantity (campo e
# saldo), reason. Quando alguma recusa já existe antes
# da trava, o saldo é lido (sem trava) só para dizer as recusas de saldo junto
# das outras; o veredito da escrita é o saldo relido sob trava.
#
# Ordem de travas (a do módulo, Pharmacy::Ledger): lote → local → ajuste.
#   1. lock_lots!([lot]) — FOR UPDATE no lote antes do movimento e do ajuste (o FK
#      de ambos pede FOR KEY SHARE no lote);
#   2. lock_location! — FOR SHARE no local e na unidade: quem grava `pending`
#      serializa com a desativação do local (SaveLocation lê `pending_work?` sob
#      FOR UPDATE do local) e da unidade (HealthUnitsController#deactivate, H14);
#   3. o ajuste.
#
# Evento `stock_adjustment.recorded` só com ids e o booleano (stock_adjustment_id,
# user_id, pending). O motivo (texto livre) nunca sai em log, evento nem erro.
module Pharmacy
  module RequestAdjustment
    KINDS = Catalog::ADJUSTMENT_KINDS
    OUTFLOW_KINDS = %w[loss expiry].freeze

    # Pedido já validado: `amount` é o saldo contado (adjustment) ou a saída (loss/expiry).
    Request = Struct.new(:kind, :amount, :reason, keyword_init: true) do
      def inspect = "#<#{self.class.name} kind=#{kind}>"
      def to_s = inspect
      def pretty_print(pp) = pp.text(inspect)
      def as_json(*) = { "kind" => kind }
    end

    module_function

    # `lot` nil (id ausente, lixo ou inexistente) entra como problema `lot_id`.
    #
    # -> Result.ok(adjustment:, movement:) (movement nil quando pending) |
    # fail(:location_inactive, details: { path: "location_id" }) |
    # fail(<primeiro erro>, details: { path:, problems: [ { path:, error: } ] })
    def call(location:, lot:, kind:, counted_quantity:, quantity:, reason:, by:, settings:, now: Time.current)
      return Result.fail(:location_inactive, details: { path: "location_id" }) unless location.active

      request, problems = validate(lot, kind, counted_quantity, quantity, reason, now.in_time_zone.to_date)
      if problems.any?
        problems += balance_problems(location, lot, request) if request.amount
        return failure(order(problems))
      end

      persist(location: location, lot: lot, request: request, by: by, settings: settings, now: now)
    end

    def persist(location:, lot:, request:, by:, settings:, now:)
      result = nil
      StockAdjustment.transaction(requires_new: true) do
        result = write(location: location, lot: lot, request: request, by: by, settings: settings, now: now)
        raise ActiveRecord::Rollback if result.failure?
      end
      result
    end

    def write(location:, lot:, request:, by:, settings:, now:)
      locked_lot = Ledger.lock_lots!([ lot.id ]).fetch(lot.id)
      Ledger.lock_location!(location.id)
      balance = Ledger.balance(location_id: location.id, lot_id: lot.id)

      problems = balance_problems_for(balance, request)
      return failure(problems) if problems.any?

      effect = effect_of(request, balance)
      pending = request.kind == "adjustment" && pending?(balance, effect, settings)
      adjustment = StockAdjustment.create!(
        stock_location: location, stock_lot: locked_lot, kind: request.kind, status: pending ? "pending" : "applied",
        quantity: effect, counted_quantity: (request.amount if request.kind == "adjustment"), balance_at_request: balance,
        reason: request.reason, requested_by_user: by, created_at: now
      )
      movement = pending ? nil : apply(location, locked_lot, adjustment, effect, by, now)
      DomainEvents.publish("stock_adjustment.recorded", stock_adjustment_id: adjustment.id, user_id: by.id, pending: pending)
      Result.ok(adjustment: adjustment, movement: movement)
    rescue Ledger::Inactive
      Result.fail(:location_inactive, details: { path: "location_id" })
    rescue Ledger::Insufficient
      # O trigger do banco, o cinto: só com o livro fora da trava.
      failure([ problem(request.kind == "adjustment" ? "counted_quantity" : "quantity", :insufficient_balance) ])
    end

    # A saída de perda/vencimento é o `quantity` do movimento (positivo; o tipo
    # dá o sinal); a contagem leva o delta com sinal.
    def apply(location, lot, adjustment, effect, by, now)
      kind = adjustment.kind
      Ledger.record!(location: location, lot: lot, kind: kind, quantity: kind == "adjustment" ? effect : -effect, by: by,
                     document: adjustment, reason: adjustment.reason, at: now)
    end

    # ---- validação (sem trava) ---------------------------------------------

    # -> [ Request | nil, [ problem ] ]. `request.amount` nil quando a quantidade é inválida.
    def validate(lot, kind, counted_quantity, quantity, reason, today)
      problems = []
      problems << problem("lot_id", :invalid_request) unless lot
      valid_kind = KINDS.include?(kind)
      problems << problem("kind", :invalid_request) unless valid_kind

      amount = nil
      if kind == "adjustment"
        amount = Quantity.parse(counted_quantity, allow_zero: true, pattern: Catalog::BALANCE_QUANTITY)
        problems << problem("counted_quantity", :invalid_quantity) unless amount
      elsif OUTFLOW_KINDS.include?(kind)
        amount = Quantity.parse(quantity)
        problems << problem("quantity", :invalid_quantity) unless amount
      end
      problems.concat(expiry_problems(lot, kind, today))

      clean = reason.is_a?(String) ? reason.strip : nil
      problems << problem("reason", :invalid_reason) unless clean && Catalog::REASON.cover?(clean.length)
      [ Request.new(kind: valid_kind ? kind : nil, amount: valid_kind ? amount : nil, reason: clean), problems ]
    end

    # O dia da validade ainda vale; o lote imutável não precisa de trava.
    def expiry_problems(lot, kind, today)
      return [] unless lot

      expired = lot.expires_on < today
      return [ problem("lot_id", :lot_not_expired) ] if kind == "expiry" && !expired
      return [ problem("lot_id", :lot_expired) ] if kind == "loss" && expired

      []
    end

    # Saldo lido sem trava, só para juntar as recusas de saldo às de campo.
    def balance_problems(location, lot, request)
      return [] unless lot

      balance_problems_for(Ledger.balance(location_id: location.id, lot_id: lot.id), request)
    end

    # -> [ problem ] com o saldo dado (lido com ou sem trava).
    def balance_problems_for(balance, request)
      if request.kind == "adjustment"
        delta = request.amount - balance
        return [ problem("counted_quantity", :no_difference) ] if delta.zero?
        return [ problem("counted_quantity", :invalid_quantity) ] if delta.abs > Catalog::MAX_QUANTITY
      elsif balance < request.amount
        return [ problem("quantity", :insufficient_balance) ]
      end
      []
    end

    # Efeito no estoque, com sinal (o que a coluna `quantity` guarda).
    def effect_of(request, balance) = request.kind == "adjustment" ? request.amount - balance : -request.amount

    def pending?(balance, delta, settings)
      balance.zero? || delta.abs * 100 > balance * settings.adjustment_approval_percent
    end

    ORDER = %w[lot_id kind counted_quantity quantity reason].freeze

    # Na ordem do roteiro (lot_id, kind, quantidade, validade, saldo, motivo), sem repetir path + erro.
    def order(problems) = problems.uniq.each_with_index.sort_by { |found, position| [ ORDER.index(found[:path]) || ORDER.size, position ] }.map(&:first)

    # ---- resultado ---------------------------------------------------------

    def problem(path, error) = { path: path, error: error.to_s }

    def failure(problems)
      first = problems.first
      Result.fail(first[:error], details: { path: first[:path], problems: problems })
    end

    private_class_method :persist, :write, :apply, :validate, :expiry_problems, :balance_problems, :balance_problems_for, :effect_of, :pending?,
                         :order, :problem, :failure
  end
end
