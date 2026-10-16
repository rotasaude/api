# Mapa de trabalho (spec §5.5; dashboard D8): itens com amostra aceita, por
# setor e bancada; filtros de urgência, data de recebimento e pendentes.
# Sem valor e sem trilha.
module Lab
  module Worklist
    module_function

    def groups(provider:, filters:)
      scope = LabRequisitionItem.joins(:lab_sample, :lab_requisition, lab_exam_version: :lab_exam)
                                .where(lab_requisitions: { exam_provider_id: provider.id }, lab_samples: { status: LabSample::ACCEPTED })
                                .where(status: filters[:pending] ? %w[pending] : %w[pending typed])
                                .includes(:lab_sample, lab_requisition: :patient, lab_exam_version: :lab_exam)
      scope = scope.where(lab_exams: { sector: filters[:sector] }) if filters[:sector]
      scope = scope.where(lab_exams: { bench: filters[:bench] }) if filters[:bench]
      scope = scope.where(lab_requisitions: { urgent: true }) if filters[:urgent]
      scope = scope.where(lab_samples: { received_at: filters[:date].in_time_zone.all_day }) if filters[:date]
      # corte silencioso em 500 (Ciclo 1): o dashboard filtra por setor/bancada/data.
      scope.order("lab_requisitions.urgent DESC, lab_samples.received_at ASC").limit(500).to_a
           .group_by { |i| [ i.lab_exam_version.lab_exam.sector, i.lab_exam_version.lab_exam.bench ] }
           .sort_by { |(sector, bench), _| [ sector, bench.to_s ] }
           .map do |(sector, bench), items|
        { sector: sector, bench: bench, items: items.map do |i|
          req = i.lab_requisition
          { item_id: i.id, requisition_id: req.id, requisition_number: req.number, barcode: i.lab_sample.barcode,
            patient_display_name: req.patient.display_name, sigtap_code: i.lab_exam_version.lab_exam.sigtap_code,
            label: i.lab_exam_version.lab_exam.name, urgent: req.urgent, received_at: i.lab_sample.received_at&.iso8601, status: i.status }
        end }
      end
    end
  end
end
