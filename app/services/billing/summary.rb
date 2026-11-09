# Resumo da competência (contrato §2 com §13 E17). Fechada: linhas do último
# arquivo e a crítica gravada no fechamento. Aberta: o mesmo recálculo das
# pendências (Billing::Pending.outcomes, sem gravar) — itens faturáveis por
# instrumento (o BPA-C ainda não agregado), contagem por motivo e pendências,
# para o resumo bater com /pending. Nos dois casos, `pending` soma a pendência
# SEM linha da urgência (Urgency::BillingPending, ADR 0050 §14 Q12), que o
# /pending também lista em qualquer estado da competência.
module Billing
  module Summary
    module_function

    def call(period)
      period.closed? ? from_export(period) : recalculated(period)
    end

    def recalculated(period)
      pairs = Pending.outcomes(period)
      blocked = pairs.map(&:last).reject(&:billable)
      billable = pairs.map(&:last).select(&:billable)
      { bpa_i_lines: billable.count { |o| o.instrument == "bpa_i" }, bpa_c_lines: billable.count { |o| o.instrument == "bpa_c" },
        not_billable: blocked.flat_map(&:reasons).tally, pending: blocked.count { |o| Pending.listed?(o) } + urgency_pending(period) }
    end

    def from_export(period)
      rows = PerformedProcedure.recorded.where(billing_period_id: period.id)
      not_billable = rows.where(billable: false).pluck(:blocking_reasons).flatten.tally
      pending = rows.where(billable: false).where.not(instrument: "not_bpa")
                    .where.not("'establishment_is_aps' = ANY (performed_procedures.blocking_reasons)").count
      export = period.exports.order(version: :desc).first
      { bpa_i_lines: export&.lines_bpa_i.to_i, bpa_c_lines: export&.lines_bpa_c.to_i, # fechada sem arquivo: só em dado semeado à mão
        not_billable: not_billable, pending: pending + urgency_pending(period) }
    end

    def urgency_pending(period) = Urgency::BillingPending.call(period).size
    private_class_method :recalculated, :from_export, :urgency_pending
  end
end
