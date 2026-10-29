# Formas JSON da regulação (contrato §2 `<regulation_request>`). Montadas na
# mão: o as_json dos modelos é redigido de propósito (R18). Quem chama a forma
# nominal grava a trilha (CareRegulation::Trail); aqui não há leitura de trilha
# nem dado em log.
module CareRegulation
  module Json
    module_function

    # events: true traz o andamento (detalhe, 201 e a lista da consulta);
    # list_item é a mesma forma sem `events`.
    def request(r, events: true, today: Time.zone.today)
      json = list_item(r, today: today)
      return json unless events

      json.merge(events: r.events.map { |e| event(e) })
    end

    def list_item(r, today: Time.zone.today)
      { id: r.id, patient: patient(r.patient), type: r.target_type, target: { code: r.target_code, name: r.target_name },
        cid10: r.cid10, ciap2: r.ciap2, justification: r.justification, suggested_color: r.suggested_color,
        color: r.color, color_reason: r.color_reason, status: r.status, requested_at: r.requested_at&.iso8601,
        due_on: r.due_on&.iso8601, overdue: r.overdue?(today), requester: requester(r), consultation_id: r.consultation_id,
        authorization: authorization(r), appointment_request_id: r.appointment_request_id, schedule: schedule(r),
        outcome: outcome(r), misses: r.misses, external: external(r), state_regulated: r.state_regulated, version: r.version }
    end

    def patient(patient)
      { id: patient.id, display_name: patient.display_name }.merge(Patients::IdentifierJson.call(patient))
    end

    def requester(r)
      { name: Screenings::Json.staff_name(r.requester_user), cbo: r.requester_cbo,
        unit: { id: r.requester_unit_id, name: r.requester_unit.name } }
    end

    # A autorização vigente só em authorized/scheduled; realizado ou encerrado
    # pela segunda falta mostra a última, mesmo liberada; nas demais situações
    # nula — a autorização consumida por uma falta não é liberada (a falta não
    # devolve a vaga), mas o pedido de volta em pending (e o que vier dele:
    # returned, denied, cancelled) não a tem mais (acréscimo do controlador,
    # Task 10).
    VIGENTE_STATUSES = %w[authorized scheduled].freeze
    LAST_STATUSES = %w[completed closed].freeze

    # Regulado pelo estado (state_regulated) não usa a cota municipal: nunca
    # mostra autorização, mesmo a antiga e consumida de antes da falta.
    def authorization(r)
      return nil if r.state_regulated

      found = case r.status
              when *VIGENTE_STATUSES then r.current_authorization
              when *LAST_STATUSES then r.authorizations.last
              end
      return nil unless found

      offer = found.care_offer
      provider = offer.care_provider
      { offer_id: offer.id, provider: { id: provider.id, name: provider.name, kind: provider.kind }, month: offer.month_label,
        skip_reason: found.skip_reason, at: found.created_at.iso8601,
        by: { name: Screenings::Json.staff_name(found.authorized_by_user) } }
    end

    def schedule(r)
      return nil unless r.scheduled_at

      { at: r.scheduled_at.iso8601, place: r.schedule_place, notes: r.schedule_notes }
    end

    # `completed` realizado; `missed` quando a segunda falta fechou o pedido
    # (o último evento missed levou a closed; missed nunca é a situação
    # atual); senão nulo.
    def outcome(r)
      return "completed" if r.status == "completed"
      return "missed" if r.status == "closed" && r.misses >= Catalog::MAX_MISSES

      nil
    end

    def external(r)
      r.external_number && { system: r.external_system, number: r.external_number }
    end

    # <provider> (contrato §6): a unidade só no prestador próprio.
    def provider(record)
      unit = record.health_unit
      { id: record.id, name: record.name, cnes: record.cnes, kind: record.kind,
        health_unit: unit && { id: unit.id, name: unit.name }, active: record.active }
    end

    # <offer> (contrato §2): used vem da Quota (contagem das autorizações não
    # liberadas), available = quantity - used. `name` do alvo quando quem
    # chama já o resolveu em lote (Targets.names_for).
    def offer(record, used:, name: nil)
      name ||= Targets.name_for(type: record.target_type, code: record.target_code) || record.target_code
      owner = record.care_provider
      { id: record.id, provider: { id: owner.id, name: owner.name, kind: owner.kind },
        target: { type: record.target_type, code: record.target_code, name: name },
        month: record.month_label, quantity: record.quantity, used: used, available: Quota.available(record, used: used) }
    end

    # `by` nulo quando o evento é do sistema (by_user_id nulo).
    def event(e)
      { status: e.status, at: e.created_at.iso8601, by: e.by_user_id ? { name: Screenings::Json.staff_name(e.by_user) } : nil,
        reason: e.reason }
    end
  end
end
