# Formas do contrato §2 (laboratório). Sem valor de resultado aqui: valores
# só em Lab::EntryJson (Task 11) e na fila de liberação (Task 17), que gravam trilha.
module Lab
  module Json
    module_function

    def lab_member?(viewer, req) = Access.member?(viewer, req.exam_provider_id)

    def requisition(req, viewer:, full: true)
      patient = req.patient
      body = { id: req.id, number: req.number,
               patient: { id: patient.id, display_name: patient.display_name, birth_date: patient.birth_date, biological_sex: req.biological_sex },
               origin_unit: { id: req.origin_unit_id, name: req.origin_unit.name }, collection_place: req.collection_place,
               urgent: req.urgent, status: req.status, expected_delivery_on: req.expected_delivery_on&.iso8601,
               reports: req.reports.map { |r| report_summary(r, viewer: viewer) },
               delivered_to: req.delivered_to, delivered_at: req.delivered_at&.iso8601 }
      return body unless full

      body.merge(items: req.items.includes(:exam_order, lab_exam_version: :lab_exam).map { |i| item(i) },
                 samples: req.samples.includes(:collected_by_user, :lab_rejection_reason).map { |s| sample(s) })
    end

    def item(i)
      version = i.lab_exam_version
      { id: i.id, exam_order_id: i.exam_order_id, sigtap_code: version.lab_exam.sigtap_code, label: version.lab_exam.name,
        version: version.version, sample_id: i.lab_sample_id, status: i.status }
    end

    def sample(s)
      { id: s.id, barcode: s.barcode, material: s.material, container: s.container, status: s.status,
        collected_at: s.collected_at&.iso8601, collected_by: Screenings::Json.staff_name(s.collected_by_user),
        received_at: s.received_at&.iso8601, rejection_reason: s.lab_rejection_reason&.name, restriction_note: s.restriction_note,
        recollection_of_id: s.recollection_of_id, shipment_id: s.lab_shipment_id }
    end

    # pdf_url (A4 do 21a) só para quem é do laboratório e só com PDF.
    def report_summary(report, viewer:)
      url = report.pdf_file && Access.member?(viewer, report.exam_provider_id) ? Exams::Files.url_for(report.pdf_file, user: viewer) : nil
      { id: report.id, version: report.version, partial: report.partial, status: report.status, signature_kind: report.signature_kind,
        released_at: report.released_at&.iso8601, released_by: Screenings::Json.staff_name(report.released_by_user),
        short_code: report.released_at ? report.short_code : nil, pdf_url: url, replaces_report_id: report.replaces_report_id }
    end
  end
end

