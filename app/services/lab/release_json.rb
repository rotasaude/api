# Fila de liberação e conferência (dashboard D9): requisição com itens,
# linhas de resultado (valor, `effective` por linha — B30) e laudos. Quem
# chama grava a trilha e confere que o leitor é do laboratório. `notified`
# e `effective` em conjuntos (uma consulta de avisos por chamada, sem N+1).
module Lab
  module ReleaseJson
    module_function

    def requisitions(reqs, viewer:)
      notified = EntryJson.notified_ids(reqs.flat_map { |req| req.items.flat_map { |item| item.results.to_a } })
      reqs.map { |req| requisition(req, viewer: viewer, notified: notified) }
    end

    def requisition(req, viewer:, notified: nil)
      items = req.items.select(&:active?)
      notified ||= EntryJson.notified_ids(items.flat_map { |item| item.results.to_a })
      patient = req.patient
      { id: req.id, number: req.number,
        patient: { id: patient.id, display_name: patient.display_name, birth_date: patient.birth_date, biological_sex: req.biological_sex },
        urgent: req.urgent, status: req.status,
        items: items.map do |item|
          version = item.lab_exam_version
          effective = Effective.ids(item)
          Json.item(item).merge(restriction_note: item.lab_sample.restriction_note,
                                results: item.results.map { |row| EntryJson.result_row(row, version, notified, effective) })
        end,
        reports: req.reports.map { |r| Json.report_summary(r, viewer: viewer) } }
    end
  end
end
