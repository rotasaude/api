# Críticos sem aviso (spec §5.7; E4; contrato B27, B30, B51/B52). Âncora: o
# laudo liberado mais recente que cobre o item (`lab_reports.released_at`,
# status released/rectified). Entra na fila a linha que VALE naquele laudo —
# a última do componente com `created_at <= released_at` —, crítica, sem aviso
# registrado (nem ela nem a linha de origem, em qualquer profundidade). Linha
# digitada/escolhida depois da liberação (retificação pendente) não entra nem
# tira nada; liberada a retificação, seu valor novo é resultado novo e pede
# aviso novo (B51). Sem janela de idade (B52): fica até ter aviso.
#
# Tudo em SQL: o contador não decifra nem carrega valor. A regra de "avisada"
# (UNNOTIFIED) é a mesma de `Lab::EntryJson.notified_ids` (cadeia chosen_from_id)
# escrita em SQL; os dois lados têm de andar juntos — o spec de paridade
# (spec/requests/lab/criticals_spec.rb) cobre profundidade 2.
module Lab
  module Criticals
    REPORT_STATUSES = "('released', 'rectified')".freeze
    JOINS = <<~SQL.squish.freeze
      JOIN lab_report_items ri ON ri.lab_requisition_item_id = lab_results.lab_requisition_item_id
      JOIN lab_reports lr ON lr.id = ri.lab_report_id AND lr.status IN #{REPORT_STATUSES} AND lr.released_at IS NOT NULL
    SQL

    # O laudo âncora é o mais recente liberado que cobre o item.
    LATEST_REPORT = <<~SQL.squish.freeze
      NOT EXISTS (SELECT 1 FROM lab_report_items ri2 JOIN lab_reports lr2 ON lr2.id = ri2.lab_report_id
                  WHERE ri2.lab_requisition_item_id = ri.lab_requisition_item_id AND lr2.status IN #{REPORT_STATUSES}
                    AND (lr2.released_at, lr2.id) > (lr.released_at, lr.id))
    SQL

    # Linha que valia na liberação (mesmo desempate de Effective.rows).
    EFFECTIVE_AT_RELEASE = <<~SQL.squish.freeze
      lab_results.created_at <= lr.released_at
      AND NOT EXISTS (SELECT 1 FROM lab_results newer
                      WHERE newer.lab_requisition_item_id = lab_results.lab_requisition_item_id
                        AND newer.analyte_key = lab_results.analyte_key AND newer.created_at <= lr.released_at
                        AND (newer.created_at, newer.id) > (lab_results.created_at, lab_results.id))
    SQL

    UNNOTIFIED = <<~SQL.squish.freeze
      NOT EXISTS (WITH RECURSIVE chain(id, parent_id) AS (
                    SELECT lab_results.id, lab_results.chosen_from_id
                    UNION
                    SELECT p.id, p.chosen_from_id FROM lab_results p JOIN chain c ON p.id = c.parent_id)
                  SELECT 1 FROM chain JOIN lab_critical_notices n ON n.lab_result_id = chain.id)
    SQL

    # Literal igual ao predicado do índice parcial idx_lab_results_critical.
    CRITICAL = "lab_results.flag::text = ANY (ARRAY['critical_low'::text, 'critical_high'::text])".freeze

    Cursor = Struct.new(:created_at, :id)

    module_function

    # Relação de LabResult (contável sem decifrar nada).
    def unnotified(provider_ids:)
      LabResult.joins(JOINS).where(CRITICAL).where("lr.exam_provider_id": provider_ids)
               .where(LATEST_REPORT).where(EFFECTIVE_AT_RELEASE).where(UNNOTIFIED)
    end

    # Página, a mais antiga liberada primeiro (released_at, id). Cada linha traz
    # `anchor_released_at`. Devolve [linhas, próximo cursor | nil].
    def page(provider_ids:, after:, limit:)
      scope = unnotified(provider_ids: provider_ids).select("lab_results.*", "lr.released_at AS anchor_released_at")
      scope = scope.where("(lr.released_at, lab_results.id) > (?, ?)", *after) if after
      rows = scope.order("lr.released_at ASC, lab_results.id ASC").limit(limit + 1).to_a
      shown = rows.first(limit)
      [ shown, rows.size > limit ? Exams::Cursor.encode(Cursor.new(shown.last.anchor_released_at, shown.last.id)) : nil ]
    end
  end
end
