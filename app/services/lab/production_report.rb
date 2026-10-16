# Relatórios do laboratório (spec §7; dashboard D13), mês no fuso da cidade.
# Produção: itens do PRIMEIRO laudo (retificação não conta de novo) com
# liberação no mês, por unidade de origem, exame, setor e liberador, com o
# valor SIGTAP (VL_SA da competência do mês; 0 se a tabela não traz).
# Rejeições: amostras rejeitadas no mês por motivo e unidade. Prazo: itens
# liberados no mês no prazo (até expected_delivery_on) ou atrasados, e os
# ainda abertos das requisições do mês.
module Lab
  module ProductionReport
    PRODUCTION_HEADERS = %w[origin_unit sigtap_code exam_name sector releaser quantity sigtap_value_cents].freeze
    REJECTION_HEADERS = %w[reason origin_unit count].freeze
    TURNAROUND_HEADERS = %w[sigtap_code exam_name on_time late pending].freeze

    module_function

    def production(provider_ids:, month:)
      items = first_release_items(provider_ids, month)
      amounts = amounts(items.map { |item, _| item.lab_exam_version.lab_exam.sigtap_code }.uniq, month)
      rows = items.group_by { |item, report| [ item.lab_requisition.origin_unit, item.lab_exam_version.lab_exam, report.released_by_user ] }
                  .map do |(unit, exam, releaser), list|
        { origin_unit: { id: unit.id, name: unit.name }, sigtap_code: exam.sigtap_code, exam_name: exam.name, sector: exam.sector,
          releaser: releaser && { id: releaser.id, name: Screenings::Json.staff_name(releaser) }, quantity: list.size,
          sigtap_value_cents: list.size * amounts.fetch(exam.sigtap_code, 0) }
      end.sort_by { |r| [ r[:origin_unit][:name], r[:exam_name] ] }
      { rows: rows, total_quantity: rows.sum { |r| r[:quantity] }, total_value_cents: rows.sum { |r| r[:sigtap_value_cents] } }
    end

    def rejections(provider_ids:, month:)
      LabSample.joins(:lab_requisition).includes(:lab_rejection_reason, lab_requisition: :origin_unit)
               .where(status: "rejected", received_at: month, lab_requisitions: { exam_provider_id: provider_ids })
               .group_by { |s| [ s.lab_rejection_reason, s.lab_requisition.origin_unit ] }
               .map { |(reason, unit), list| { reason: { id: reason.id, name: reason.name }, origin_unit: { id: unit.id, name: unit.name }, count: list.size } }
               .sort_by { |r| [ -r[:count], r[:reason][:name] ] }
    end

    def turnaround(provider_ids:, month:)
      released = first_release_items(provider_ids, month)
      open_items = LabRequisitionItem.joins(:lab_requisition).includes(lab_exam_version: :lab_exam)
                                     .where(status: %w[pending typed], lab_requisitions: { exam_provider_id: provider_ids, created_at: month })
      exams = (released.map { |i, _| i.lab_exam_version.lab_exam } + open_items.map { |i| i.lab_exam_version.lab_exam }).uniq(&:sigtap_code)
      exams.sort_by(&:name).map do |exam|
        mine = released.select { |i, _| i.lab_exam_version.lab_exam.sigtap_code == exam.sigtap_code }
        on_time = mine.count { |i, r| r.released_at.in_time_zone.to_date <= i.lab_requisition.expected_delivery_on }
        { sigtap_code: exam.sigtap_code, exam_name: exam.name, on_time: on_time, late: mine.size - on_time,
          pending: open_items.count { |i| i.lab_exam_version.lab_exam.sigtap_code == exam.sigtap_code } }
      end
    end

    # [[item, primeiro laudo que o liberou]]
    def first_release_items(provider_ids, month)
      LabReportItem.joins(:lab_report)
                   .where(lab_reports: { exam_provider_id: provider_ids, replaces_report_id: nil, status: %w[released rectified], released_at: month })
                   .includes(lab_report: :released_by_user, lab_requisition_item: [ { lab_requisition: :origin_unit }, { lab_exam_version: :lab_exam } ])
                   .map { |ri| [ ri.lab_requisition_item, ri.lab_report ] }
    end

    def amounts(codes, month)
      release = Terminology::Sigtap.release_for(month.first.strftime("%Y%m"))
      return {} unless release

      SigtapProcedure.where(release_id: release.id, code: codes).pluck(:code, :amount_sa_cents).to_h.transform_values(&:to_i)
    end
    private_class_method :first_release_items, :amounts
  end
end
