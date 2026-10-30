# O que já saiu de cada item da receita (ADR 0045, Desvio 9; contrato H3): o
# total dispensado, o dia da última retirada (no fuso da cidade) e se alguém
# marcou o item como completo. Conta por ITEM da receita.
#
# Devolução (Desvio 12) abate: o total é LÍQUIDO (dispensado − devolvido),
# porque devolver libera nova retirada. Uma linha devolvida por inteiro é como
# se não tivesse saído: não conta para a última retirada (o intervalo do uso
# contínuo) nem para o `completed`. Devolução parcial mantém a linha.
module Pharmacy
  module Dispensed
    module_function

    # -> { item_id => { total: BigDecimal, last_on: Date|nil, completed: bool } }
    # (todo item da receita aparece, com zero se nada saiu).
    def summary(prescription) = summaries([ prescription ]).fetch(prescription.id)

    # Numa consulta por tipo de receita (mais uma para as devoluções):
    # { prescription_id => summary }.
    def summaries(prescriptions)
      prescriptions.group_by(&:kind).each_with_object({}) do |(kind, group), result|
        column = kind == "digital" ? :prescription_item_id : :external_prescription_item_id
        ids = group.flat_map { |prescription| prescription.items.map(&:id) }
        rows = DispensationItem.joins(:dispensation).where(column => ids)
                               .pluck(:id, column, :quantity, :completes_item, "dispensations.dispensed_at")
        returned = returned_totals(rows.map(&:first))
        lines = rows.filter_map do |id, item_id, quantity, completes, at|
          net = quantity - returned.fetch(id, BigDecimal("0"))
          { item_id: item_id, net: net, completes: completes, at: at } if net.positive?
        end.group_by { |line| line[:item_id] }
        group.each do |prescription|
          result[prescription.id] = prescription.items.to_h do |item|
            found = lines.fetch(item.id, [])
            [ item.id, { total: found.sum(BigDecimal("0")) { |line| line[:net] }, last_on: found.map { |line| line[:at] }.max&.in_time_zone&.to_date,
                         completed: found.any? { |line| line[:completes] } } ]
          end
        end
      end
    end

    # Última retirada por item do CATÁLOGO do paciente, em todos os locais (27a,
    # H7; lista de medicamentos em uso): { catalog_item_id => Date } no fuso da
    # cidade. Líquida como o resto: uma linha devolvida POR INTEIRO não conta
    # (a dispensação inteira só some se todas as suas linhas voltaram).
    def last_on(patient_id)
      rows = DispensationItem.joins(:dispensation).where(dispensations: { patient_id: patient_id })
                             .pluck(:id, :catalog_item_id, :quantity, "dispensations.dispensed_at")
      returned = returned_totals(rows.map(&:first))
      rows.filter_map { |id, catalog_item_id, quantity, at| [ catalog_item_id, at ] if (quantity - returned.fetch(id, BigDecimal("0"))).positive? }
          .group_by(&:first).transform_values { |lines| lines.map(&:last).max.in_time_zone.to_date }
    end

    # Devolvido por item dispensado: { dispensation_item_id => BigDecimal }.
    def returned_totals(dispensation_item_ids)
      return {} if dispensation_item_ids.empty?

      StockMovement.where(kind: "return", dispensation_item_id: dispensation_item_ids).group(:dispensation_item_id).sum(:quantity)
                   .transform_values(&:to_d)
    end
  end
end
