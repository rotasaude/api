# Formas do contrato §2 (com as Divergências D4, D5 e D16).
module Exams
  module Json
    module_function

    def order(order, view:, user:, events: true)
      clinical = view == :clinical
      body = {
        id: order.id, short_code: order.short_code,
        patient: { id: order.patient_id, display_name: order.patient.display_name },
        sigtap_code: order.sigtap_code, sigtap_competence: order.sigtap_competence,
        label: Labels.exam(order.sigtap_code, order.sigtap_competence), priority: order.priority,
        cid10_justification: clinical ? order.cid10_justification : nil, origin: order.origin,
        consultation_id: order.consultation_exam_request&.consultation_id,
        requester: { user_id: order.requester_user_id, name: order.requester_display_name, cns: clinical ? order.requester_cns : nil },
        unit: { id: order.unit_id, name: order.unit.name },
        provider: order.exam_provider && { id: order.exam_provider_id, name: order.exam_provider.name },
        scheduled_at: order.scheduled_at&.iso8601, scheduled_place: order.scheduled_place,
        external_reference: order.external_reference, status: order.status, status_changed_at: order.status_changed_at.iso8601,
        overdue: overdue(order), escalated: order.escalated?,
        guide_url: order.guide_file && Files.url_for(order.guide_file, user: user),
        result: order.result && result(order.result, view: view, user: user)
      }
      if events
        body[:events] = order.events.includes(:actor_user, :actor_provider).map { |e| event(e, view: view) }
        body[:result_fields] = result_fields(order) # dashboard D6: o formulário de resultado
      end
      body
    end

    def result_fields(order)
      Array(order.catalog_item&.result_fields).map { |f| f.slice("key", "label", "unit", "loinc") }
    end

    def overdue(order)
      late = order.overdue
      late && { stage: late[:stage], due_on: late[:due_on].iso8601, days_late: late[:days_late] }
    end

    def result(result, view:, user:)
      base = { id: result.id, origin: result.origin, source: result.source, released_on: result.released_on.iso8601,
               laboratory_name: result.laboratory_name }
      return base unless view == :clinical

      acknowledged = result.exam_order&.events&.select { |e| e.kind == "acknowledged" }&.last
      base.merge(critical: result.critical, values: result.values_list, pdf_url: Files.url_for(result.pdf_file, user: user),
                 acknowledged_at: (acknowledged&.occurred_at || (result.external? ? result.created_at : nil))&.iso8601)
    end

    def event(event, view:)
      actor = if event.actor_provider then { type: "provider", name: event.actor_provider.name }
              elsif event.actor_user then { type: "user", name: Screenings::Json.staff_name(event.actor_user) }
              else { type: "system", name: nil }
              end
      reason = event.kind == "escalated" ? event.escalation_reason : (view == :clinical ? event.reason : nil)
      { kind: event.kind, occurred_at: event.occurred_at.iso8601, actor: actor, reason: reason }
    end

    # Portal do prestador (contrato §2): nunca prontuário — nome, nascimento
    # e os 3 últimos dígitos do CPF.
    def provider_order(order)
      patient = order.patient
      { id: order.id, short_code: order.short_code,
        patient: { name: patient.display_name, birth_date: patient.birth_date, cpf_last3: patient.cpf.to_s[-3, 3] },
        sigtap_code: order.sigtap_code, label: Labels.exam(order.sigtap_code, order.sigtap_competence),
        priority: order.priority, status: order.status, scheduled_at: order.scheduled_at&.iso8601,
        scheduled_place: order.scheduled_place, overdue: overdue(order), result_fields: result_fields(order) }
    end
  end
end
