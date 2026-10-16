# A linha que vale de cada componente (Desvio 9; B30): a última do componente.
# Desempate determinístico (E5): `created_at` é estritamente crescente por
# item+componente (EnterResults.create_row garante), então a ordem de inserção
# decide; o `id` (UUID aleatório) só entra como último recurso, nunca como regra.
module Lab
  module Effective
    module_function

    def rows(item)
      item.results.to_a.group_by(&:analyte_key).transform_values { |list| list.max_by { |r| [ r.created_at, r.id ] } }
    end

    # Ids das linhas que valem (para o `effective` de cada linha no JSON).
    def ids(item) = rows(item).values.to_set(&:id)

    def complete?(item)
      present = rows(item).keys
      item.lab_exam_version.analytes.all? { |a| present.include?(a["key"]) }
    end
  end
end
