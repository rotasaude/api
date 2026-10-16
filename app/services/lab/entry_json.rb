# Item para digitar e conferir (dashboard D7): componentes com a faixa já
# escolhida e as linhas (valor só para quem é do laboratório — quem chama confere).
#
# Cada linha traz `effective` (B30): true na última de cada componente
# (Lab::Effective); `chosen` fica só como histórico. `notified` (L9) conta o
# aviso registrado na própria linha ou na linha de que ela foi escolhida
# (chosen_from_id, em cadeia), como Lab::Criticals.unnotified deverá fazer.
# NOTA: Lab::Criticals ainda não existe (Task 16); quando existir, as duas
# regras devem usar a mesma definição.
module Lab
  module EntryJson
    module_function

    def item(item)
      req = item.lab_requisition
      ctx = EnterResults.context(item)
      version = item.lab_exam_version
      rows = item.results.includes(:entered_by_user).to_a
      notified = notified_ids(rows)
      effective = Effective.ids(item)
      { item_id: item.id, requisition_id: req.id, requisition_number: req.number, barcode: item.lab_sample.barcode,
        patient: { display_name: req.patient.display_name, birth_date: req.patient.birth_date, biological_sex: req.biological_sex },
        sigtap_code: version.lab_exam.sigtap_code, label: version.lab_exam.name, version: version.version, status: item.status,
        sample_status: item.lab_sample.status, restriction_note: item.lab_sample.restriction_note,
        analytes: version.analytes.map { |a| analyte(a, Reference.range_for(a, **ctx)) },
        results: rows.map { |row| result_row(row, version, notified, effective) } }
    end

    # Só a lista de itens da amostra (B39): sem valor, sem paciente.
    def sample_item(item)
      { item_id: item.id, sigtap_code: item.lab_exam_version.lab_exam.sigtap_code, name: item.lab_exam_version.lab_exam.name, status: item.status }
    end

    def analyte(a, range)
      { key: a["key"], name: a["name"], unit: a["unit"], value_type: a["value_type"], choices: a["value_type"] == "choice" ? a["choices"] : nil,
        decimals: a["decimals"], reference: range && range.slice("low", "high", "text"), entry_min: a["entry_min"], entry_max: a["entry_max"],
        critical_low: a["critical_low"], critical_high: a["critical_high"], formula: a["formula"] }
    end

    # `notified`/`effective` opcionais: sem eles, calculados do item da linha
    # (uma consulta a mais por linha; quem monta lista passa os conjuntos).
    def result_row(row, version = row.lab_requisition_item.lab_exam_version, notified = nil, effective = nil)
      item = row.lab_requisition_item
      effective ||= Effective.ids(item)
      body = { id: row.id, item_id: row.lab_requisition_item_id, analyte_key: row.analyte_key, name: version.analyte(row.analyte_key)&.fetch("name"),
               value: row.value, unit: row.unit, flag: row.flag, source: row.source, entered_at: row.entered_at.iso8601,
               entered_by: Screenings::Json.staff_name(row.entered_by_user), chosen: row.chosen, effective: effective.include?(row.id) }
      body[:notified] = (notified || notified_ids(item.results.to_a)).include?(row.id) if row.critical?
      body
    end

    # Ids das linhas avisadas: com aviso próprio ou numa linha de origem.
    def notified_ids(rows)
      noticed = LabCriticalNotice.where(lab_result_id: rows.map(&:id)).distinct.pluck(:lab_result_id).to_set
      by_id = rows.index_by(&:id)
      rows.select do |row|
        seen = Set.new
        current = row
        found = false
        while current && seen.add?(current.id)
          found = noticed.include?(current.id)
          break if found

          current = by_id[current.chosen_from_id]
        end
        found
      end.to_set(&:id)
    end
  end
end
