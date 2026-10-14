# Abre o exame (ADR 0036; Desvio 8): status inicial pelo catálogo
# (exige autorização → awaiting_authorization), prazo da primeira etapa,
# evento requested e exam_order.requested (só ids). Savepoint próprio: roda
# dentro da finalização da consulta sem derrubá-la.
module Exams
  module Open
    module_function

    def call(patient:, sigtap_code:, priority:, unit:, origin:, created_by:, requester_user: nil, requester_name: nil,
             requester_cns: nil, cid10: nil, consultation_exam_request: nil, guide_file: nil, external_reference: nil,
             sigtap_competence: nil, require_catalog: true, now: Time.current)
      return Result.fail(:invalid_priority) unless ExamOrder::PRIORITIES.include?(priority)

      item = ExamCatalogItem.find_by(sigtap_code: sigtap_code, active: true)
      return Result.fail(:sigtap_not_in_catalog) if require_catalog && item.nil?

      competence = sigtap_competence || ClinicalTerms::SigtapExams.find(sigtap_code, on: now.in_time_zone.to_date)&.competence
      return Result.fail(:sigtap_not_in_catalog) unless competence

      status = item&.requires_authorization ? "awaiting_authorization" : "awaiting_schedule"
      stage = status == "awaiting_authorization" ? "authorize" : "schedule"
      due = now.in_time_zone.to_date + Deadlines.days(stage: stage, sigtap_code: sigtap_code, provider_id: nil, priority: priority)
      ApplicationRecord.transaction(requires_new: true) do
        order = ExamOrder.create!(patient: patient, sigtap_code: sigtap_code, sigtap_competence: competence, priority: priority,
                                  cid10_justification: cid10, requester_user: requester_user, requester_name: requester_name,
                                  requester_cns: requester_cns, unit: unit, origin: origin,
                                  consultation_exam_request: consultation_exam_request, guide_file: guide_file,
                                  external_reference: external_reference, short_code: short_code, status: status,
                                  status_changed_at: now, stage: stage, stage_opened_at: now, stage_due_on: due,
                                  created_by_user: created_by)
        ExamOrderEvent.create!(exam_order: order, kind: "requested", actor_user: requester_user || created_by, occurred_at: now)
        DomainEvents.publish("exam_order.requested", exam_order_id: order.id, origin: origin, priority: priority)
        Result.ok(order: order)
      end
    end

    def short_code
      loop do
        code = ClinicalDocuments::Codes.short_code
        return code unless ExamOrder.exists?(short_code: code)
      end
    end
    private_class_method :short_code
  end
end
