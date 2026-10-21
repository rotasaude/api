# Produção do laboratório municipal (ADR 0039; contrato §4 e §13 E10): um
# procedimento por item do PRIMEIRO laudo liberado (replaces_report_id nulo;
# o original já retificado antes do consumidor rodar ainda vale; o laudo
# retificador e o retirado não criam), com o laboratório como
# estabelecimento, o liberador como profissional (CBO do vínculo dele), a
# data da coleta e quantidade 1. Idempotente por item (consulta + índice
# único em lab_report_item_id).
module Billing
  module FromLab
    PRODUCING = %w[released rectified].freeze

    module_function

    def call(report)
      return 0 unless PRODUCING.include?(report.status) && report.replaces_report_id.nil?

      provider = report.exam_provider
      return 0 unless provider.uses_municipal_lab

      establishment = Establishment.for_lab(provider)
      releaser = report.released_by_user
      cbo = Staff.cbo_for(releaser, establishment)
      items = report.report_items.includes(lab_requisition_item: [ :lab_sample, :lab_requisition, { lab_exam_version: :lab_exam } ]).order(:id)
      items.count do |report_item|
        next false if PerformedProcedure.exists?(lab_report_item_id: report_item.id)

        item = report_item.lab_requisition_item
        Record.insert!(patient: item.lab_requisition.patient, establishment: establishment, professional: releaser, cbo_code: cbo,
                       source: "lab_report", performed_on: (item.lab_sample.collected_at || report.released_at).in_time_zone.to_date,
                       sigtap_code: item.lab_exam_version.lab_exam.sigtap_code, quantity: 1, cid10: nil, character: "elective",
                       recorded_by: nil, lab_report_item: report_item)
        true
      end
    end
  end
end
