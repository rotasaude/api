# Pagamento registrado da ajuda de custo (contrato §6; §14 T8, T18, T24): a
# comissão (o step-up é da rota) registra data, valor, forma e recibo — só
# acréscimo (trigger). Só em `scheduled`/`travelling`; `paid_on` de hoje até
# 365 dias atrás; valor 1..MAX_AMOUNT_CENTS; recibo 1..40. Recusas de campo
# todas de uma vez. Recibo já usado no processo → 409 `receipt_taken` (índice
# único; o POST repetido não duplica o pagamento imutável — FR I3). Publica
# tfd.payment_recorded só com ids (o recibo e o valor nunca vão a evento nem log).
module Tfd
  module RecordPayment
    OPEN = %w[scheduled travelling].freeze
    KEYS = %w[paid_on amount_cents method receipt_number].freeze
    WINDOW = 365
    RECEIPT_INDEX = "idx_tfd_payments_receipt".freeze

    module_function

    # attrs: o corpo JSON. -> Result.ok(tfd_case:, payment:) | fail(:missing_role | :invalid_request | :invalid_transition |
    #    :receipt_taken)
    def call(tfd_case:, attrs:, by:)
      return Result.fail(:missing_role) unless Access.committee?(by)

      attrs = attrs.to_h.stringify_keys
      today = Date.current
      paid_on = Transport::Support.date(attrs["paid_on"])
      amount = Transport::Support.integer(attrs["amount_cents"], 1..Catalog::MAX_AMOUNT_CENTS)
      payment_method = attrs["method"] if Catalog::PAYMENT_METHODS.include?(attrs["method"])
      receipt = Transport::Support.text(attrs["receipt_number"], 1..Catalog::RECEIPT_MAX)
      paths = (attrs.keys - KEYS).map { |key| key.to_s[0, 64] }
      paths << "paid_on" unless paid_on && paid_on <= today && paid_on >= today - WINDOW
      paths << "amount_cents" unless amount
      paths << "method" unless payment_method
      paths << "receipt_number" unless receipt
      return Transport::Support.refuse(paths) if paths.any?

      TfdCase.transaction(requires_new: true) do
        tfd_case.lock!
        next Result.fail(:invalid_transition) unless OPEN.include?(tfd_case.status)

        payment = TfdPayment.create!(tfd_case: tfd_case, paid_on: paid_on, amount_cents: amount, payment_method: payment_method,
                                     receipt_number: receipt, by_user: by)
        DomainEvents.publish("tfd.payment_recorded", tfd_case_id: tfd_case.id, tfd_payment_id: payment.id, user_id: by.id)
        Result.ok(tfd_case: tfd_case, payment: payment)
      end
    rescue ActiveRecord::RecordNotUnique => e
      raise unless e.message.include?(RECEIPT_INDEX)

      Transport::Support.refuse_with(:receipt_taken, "receipt_number")
    end
  end
end
