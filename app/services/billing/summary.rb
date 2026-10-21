# Resumo da competência (contrato §2). Fechada: linhas do último arquivo.
# Aberta: itens faturáveis por instrumento (o BPA-C ainda não agregado),
# contagem por motivo e pendências — com a crítica gravada (sem recalcular;
# o recálculo é das pendências e do fechamento).
module Billing
  module Summary
    module_function

    def call(period)
      rows = PerformedProcedure.recorded.where(billing_period_id: period.id)
      not_billable = rows.where(billable: false).pluck(:blocking_reasons).flatten.tally
      pending = rows.where(billable: false).where.not(instrument: "not_bpa")
                    .where.not("'establishment_is_aps' = ANY (performed_procedures.blocking_reasons)").count
      export = period.closed? ? period.exports.order(version: :desc).first : nil
      { bpa_i_lines: export ? export.lines_bpa_i : rows.where(billable: true, instrument: "bpa_i").count,
        bpa_c_lines: export ? export.lines_bpa_c : rows.where(billable: true, instrument: "bpa_c").count,
        not_billable: not_billable, pending: pending }
    end
  end
end
