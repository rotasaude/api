# O que já saiu de cada item da receita (ADR 0045, Desvio 9; contrato H3): o
# total dispensado, o dia da última retirada (no fuso da cidade) e se alguém
# marcou o item como completo. Conta por ITEM da receita. Devolução não entra
# na conta: o total é o que foi dispensado.
module Pharmacy
  module Dispensed
    module_function

    # -> { item_id => { total: BigDecimal, last_on: Date|nil, completed: bool } }
    # (todo item da receita aparece, com zero se nada saiu).
    def summary(prescription) = summaries([ prescription ]).fetch(prescription.id)

    # Numa consulta por tipo de receita: { prescription_id => summary }.
    def summaries(prescriptions)
      prescriptions.group_by(&:kind).each_with_object({}) do |(kind, group), result|
        column = kind == "digital" ? :prescription_item_id : :external_prescription_item_id
        ids = group.flat_map { |prescription| prescription.items.map(&:id) }
        rows = DispensationItem.joins(:dispensation).where(column => ids)
                               .pluck(column, :quantity, :completes_item, "dispensations.dispensed_at").group_by(&:first)
        group.each do |prescription|
          result[prescription.id] = prescription.items.to_h do |item|
            lines = rows.fetch(item.id, [])
            [ item.id, { total: lines.sum(BigDecimal("0")) { |line| line[1] }, last_on: lines.map { |line| line[3] }.max&.in_time_zone&.to_date,
                         completed: lines.any? { |line| line[2] } } ]
          end
        end
      end
    end
  end
end
