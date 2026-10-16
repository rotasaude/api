# Formas do contrato §2 (com as Divergências D4, D5 e D16).
module Exams
  module Json
    # A32: o motivo de negar e cancelar vai também à visão administrativa; o
    # do escalonamento e o da ciência pela equipe, só à clínica.
    ADMINISTRATIVE_REASON_KINDS = %w[denied cancelled].freeze

    module_function

    # A42: `cid10: true` leva o CID à visão administrativa do regulador (fila e
    # detalhe); o CNS do solicitante nunca sai dela. A47: `denied_reason: true`
    # (só os itens de `denied` da lista do solicitante, visão clínica) leva o
    # motivo do evento denied; nunca ao cidadão.
    def order(order, view:, user:, events: true, cid10: false, denied_reason: false)
      clinical = view == :clinical
      body = {
        id: order.id, short_code: order.short_code,
        patient: { id: order.patient_id, display_name: order.patient.display_name },
        sigtap_code: order.sigtap_code, sigtap_competence: order.sigtap_competence,
        label: Labels.exam(order.sigtap_code, order.sigtap_competence), priority: order.priority,
        cid10_justification: clinical || cid10 ? order.cid10_justification : nil, origin: order.origin,
        consultation_id: order.consultation_exam_request&.consultation_id,
        consultation_exam_request_id: order.consultation_exam_request_id, # A45
        requester: { user_id: order.requester_user_id, name: order.requester_display_name, cns: clinical ? order.requester_cns : nil },
        unit: { id: order.unit_id, name: order.unit.name },
        provider: order.exam_provider && { id: order.exam_provider_id, name: order.exam_provider.name },
        scheduled_at: order.scheduled_at&.iso8601, scheduled_place: order.scheduled_place,
        external_reference: order.external_reference, gal_requisition: order.gal_requisition, # v1.1 (B24): chave sempre presente
        status: order.status, status_changed_at: order.status_changed_at.iso8601,
        overdue: overdue(order), escalated: order.escalated?,
        escalation_reasons: clinical ? escalation_reasons(order) : nil, # B63: o gravado, sem deduzir
        guide_url: order.guide_file && Files.url_for(order.guide_file, user: user),
        result: order.result && result(order.result, view: view, user: user)
      }
      body[:denied_reason] = order.events.select { |e| e.kind == "denied" }.last&.reason if denied_reason && clinical
      if events
        body[:events] = order.events.includes(:actor_user, :actor_provider).map { |e| event(e, view: view) }
        body[:result_fields] = result_fields(order) # dashboard D6: o formulário de resultado
        # Dashboard D16 (B8): resultados substituídos, só na visão clínica, do mais novo ao mais antigo.
        body[:superseded_results] = superseded_results(order, view: view, user: user) if clinical
      end
      body
    end

    # A31: no máximo um escalonamento por motivo, na ordem em que ocorreram.
    def escalation_reasons(order)
      order.events.select { |e| e.kind == "escalated" }.sort_by(&:occurred_at).map(&:escalation_reason)
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

      acknowledged = acknowledgement(result)
      base.merge(critical: result.critical, values: result.values_list, pdf_url: Files.url_for(result.pdf_file, user: user),
                 acknowledged_at: (acknowledged&.occurred_at || (result.external? ? result.created_at : nil))&.iso8601,
                 replaces_result_id: result.replaces_result_id)
    end

    def superseded_results(order, view:, user:)
      results = order.results.to_a
      replaced_at = results.select(&:replaces_result_id).to_h { |r| [ r.replaces_result_id, r.created_at ] }
      results.select { |r| replaced_at.key?(r.id) }.reverse.map do |r|
        result(r, view: view, user: user).merge(superseded_at: replaced_at[r.id].iso8601)
      end
    end

    # E17/D7: a ciência de um resultado é a primeira `acknowledged` depois do
    # evento que o trouxe (o k-ésimo `resulted`/`result_rectified` é o do
    # k-ésimo resultado do pedido) e antes do seguinte — a ciência antiga
    # nunca vale para o resultado retificado.
    def acknowledgement(result)
      order = result.exam_order
      return nil unless order

      # L3: o original é sempre o 1º (sem consulta a mais nas listas).
      index = result.replaces_result_id ? (order.results.index { |r| r.id == result.id } || 0) : 0
      seen = -1
      order.events.each do |e|
        if %w[resulted result_rectified].include?(e.kind)
          seen += 1
          break if seen > index
        elsif e.kind == "acknowledged" && seen == index
          return e
        end
      end
      nil
    end

    def event(event, view:)
      # A35: com prestador, o ator visível é o prestador (o funcionário do
      # laboratório, também gravado, fica só na trilha do banco).
      actor = if event.actor_provider then { type: "provider", name: event.actor_provider.name }
              elsif event.actor_user then { type: "user", name: Screenings::Json.staff_name(event.actor_user) }
              else { type: "system", name: nil }
              end
      reason = event.kind == "escalated" ? event.escalation_reason : event.reason
      reason = nil unless view == :clinical || ADMINISTRATIVE_REASON_KINDS.include?(event.kind)
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
