# Críticos sem aviso (spec §5.7; E4; contrato B27, B30, B51–B53). Entra na fila
# toda linha crítica que era a que VALIA (a última do componente com
# `created_at <= lr.created_at`, conteúdo congelado na criação do laudo; N1) em
# QUALQUER laudo liberado/retificado do item (B53: retificar para valor normal
# não tira a obrigação) e fica até ter aviso (B52, sem janela de idade). Sem aviso
# = nem ela nem a linha de origem, em qualquer profundidade. Linha digitada ou
# escolhida depois (retificação pendente) não entra nem tira nada; o valor
# crítico novo de uma retificação é resultado novo e pede aviso novo (B51).
#
# Tudo em SQL, guiado pelo índice parcial de críticos (idx_lab_results_critical):
# o contador não decifra nem carrega valor. A regra de "avisada" (UNNOTIFIED) é
# a mesma de `Lab::EntryJson.notified_ids` (cadeia chosen_from_id) em SQL; os
# dois lados andam juntos — o spec de paridade cobre profundidade 2.
module Lab
  module Criticals
    REPORT_STATUSES = "('released', 'rectified')".freeze

    # Laudos liberados do item em que a linha era a que valia (mesmo desempate
    # de Effective.rows), contados a partir do conteúdo congelado na criação do
    # laudo (`lr.created_at`; N1). LATERAL devolve uma linha por resultado, a do
    # laudo liberado mais antigo (`released_at` = quando entrou na fila); sem
    # nenhum laudo assim, o resultado não entra (JOIN, não LEFT).
    ANCHOR = <<~SQL.squish.freeze
      JOIN LATERAL (
        SELECT lr.released_at FROM lab_report_items ri
        JOIN lab_reports lr ON lr.id = ri.lab_report_id AND lr.status IN #{REPORT_STATUSES} AND lr.released_at IS NOT NULL
        WHERE ri.lab_requisition_item_id = lab_results.lab_requisition_item_id AND lr.exam_provider_id IN (%<ids>s)
          AND lab_results.created_at <= lr.created_at
          AND NOT EXISTS (SELECT 1 FROM lab_results newer
                          WHERE newer.lab_requisition_item_id = lab_results.lab_requisition_item_id
                            AND newer.analyte_key = lab_results.analyte_key AND newer.created_at <= lr.created_at
                            AND (newer.created_at, newer.id) > (lab_results.created_at, lab_results.id))
        ORDER BY lr.released_at, lr.id LIMIT 1) anchor ON true
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

    # Exams::Cursor.encode lê `created_at`; aqui o campo guardado é o released_at do laudo.
    Cursor = Struct.new(:released_at, :id) do
      alias_method :created_at, :released_at
    end

    module_function

    # Relação de LabResult (contável sem decifrar nada).
    def unnotified(provider_ids:)
      ids = Array(provider_ids).map { |id| LabResult.connection.quote(id) }.join(", ").presence || "NULL"
      LabResult.joins(format(ANCHOR, ids: ids)).where(CRITICAL).where(UNNOTIFIED)
    end

    # Página, a mais antiga liberada primeiro (released_at, id). Cada linha traz
    # `anchor_released_at`. Devolve [linhas, próximo cursor | nil].
    def page(provider_ids:, after:, limit:)
      scope = unnotified(provider_ids: provider_ids).select("lab_results.*", "anchor.released_at AS anchor_released_at")
      scope = scope.where("(anchor.released_at, lab_results.id) > (?, ?)", *after) if after
      rows = scope.order("anchor.released_at ASC, lab_results.id ASC").limit(limit + 1).to_a
      shown = rows.first(limit)
      [ shown, rows.size > limit ? Exams::Cursor.encode(Cursor.new(shown.last.anchor_released_at, shown.last.id)) : nil ]
    end
  end
end
