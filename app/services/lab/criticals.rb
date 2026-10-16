# Críticos sem aviso (spec §5.7; E4): a linha que vale (B30) de cada componente
# de item liberado nos últimos 30 dias, crítica (B27, inclusiva), sem aviso
# registrado — nem para ela nem para a linha de onde foi escolhida, em qualquer
# profundidade (a mesma regra de EntryJson.notified_ids, aqui em SQL; a spec
# confere a paridade). Tudo no banco: não decifra valor nem carrega resultado
# fora da lista pedida. O momento da liberação é o `updated_at` do item (a
# transição para `released` é a última escrita do item).
module Lab
  module Criticals
    WINDOW = 30.days

    # Linha que vale: não há outra mais nova no mesmo item+componente
    # (mesmo desempate de Effective.rows: created_at, depois id).
    EFFECTIVE = <<~SQL.squish.freeze
      NOT EXISTS (SELECT 1 FROM lab_results newer
                  WHERE newer.lab_requisition_item_id = lab_results.lab_requisition_item_id
                    AND newer.analyte_key = lab_results.analyte_key
                    AND (newer.created_at, newer.id) > (lab_results.created_at, lab_results.id))
    SQL

    # Avisada: ela ou qualquer linha da cadeia chosen_from_id tem aviso.
    UNNOTIFIED = <<~SQL.squish.freeze
      NOT EXISTS (WITH RECURSIVE chain(id, parent_id) AS (
                    SELECT lab_results.id, lab_results.chosen_from_id
                    UNION
                    SELECT p.id, p.chosen_from_id FROM lab_results p JOIN chain c ON p.id = c.parent_id)
                  SELECT 1 FROM chain JOIN lab_critical_notices n ON n.lab_result_id = chain.id)
    SQL

    module_function

    def unnotified(provider_ids:, now: Time.current)
      LabResult.joins(lab_requisition_item: :lab_requisition)
               .where(flag: LabResult::CRITICAL, lab_requisition_items: { status: "released" },
                      lab_requisitions: { exam_provider_id: provider_ids })
               .where("lab_requisition_items.updated_at >= ?", now - WINDOW)
               .where(EFFECTIVE).where(UNNOTIFIED)
    end
  end
end
