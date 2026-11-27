module Regulation
  # Formas JSON da situação e da lista do envio da regulação à RNDS (módulo 26c,
  # Task 14; Q11). Escrito à mão: o `as_json` dos modelos é redigido (R18).
  # Nunca sai paciente, CPF, CNS, CID, alvo nem payload (§9), nem
  # `retry_window_started_at` e `unanswered_closed_at` (Q25). `request_ref` = os
  # 8 primeiros hex do id do pedido, em maiúsculas (rótulo e link ao detalhe).
  # O `fix` leva só ids (e o mês da oferta) para o atalho da correção, só do
  # motivo que o pede; nada do paciente. Roda dentro de `CityConnection.with`.
  module RndsJson
    # Associações que o `fix` lê (a lista de até 100 linhas sem N+1).
    PRELOAD = { regulation_request: [ :care_provider, { authorizations: { care_offer: :care_provider } } ] }.freeze

    module_function

    def status(usable:, missing:, counts:, initial_load_pending:)
      { usable: usable, missing: missing, counts: counts, late_banner: counts.fetch(:late).positive?,
        initial_load_pending: initial_load_pending }
    end

    def item(sync, now:)
      request = sync.regulation_request
      { id: sync.id, regulation_request_id: sync.regulation_request_id, request_ref: request_ref(sync.regulation_request_id),
        status: sync.status, sent_status: sync.sent_status, desired_status: sync.desired_status,
        blocked_reasons: sync.blocked_reasons, last_error_codes: sync.last_error_codes, attempts: sync.attempts,
        enqueued_at: sync.enqueued_at.iso8601, last_accepted_at: sync.last_accepted_at&.iso8601,
        next_attempt_at: sync.next_attempt_at&.iso8601, late: RndsAlert.late?(sync, now: now),
        fix: fix(sync, request) }
    end

    def request_ref(request_id) = request_id.delete("-")[0, 8].upcase

    # { offer_id, provider_id, unit_id, offer_month, settings }, todos nulos
    # (settings false) quando o motivo não tem atalho. Executante sem CNES
    # numa falta: o do horário faltado (a unidade do `no_show` na rede
    # própria, o prestador da linha no externo), como na conferência, e não o
    # da autorização vigente.
    def fix(sync, request)
      reasons = sync.blocked_reasons
      offer = request.current_authorization&.care_offer
      provider = offer&.care_provider || request.care_provider
      cbo = reasons.include?("performer_cbo_missing")
      cnes = reasons.include?("performer_without_cnes")
      slot = cnes ? absence_slot(sync, request) : nil
      performer_provider_id, performer_unit_id = slot ? [ slot.provider_id, slot.unit_id ] : [ provider&.id, provider&.health_unit_id ]
      {
        offer_id: cbo ? offer&.id : nil,
        provider_id: cbo || cnes ? performer_provider_id : nil,
        unit_id: unit_id(reasons, request, performer_unit_id, cnes),
        offer_month: cbo ? offer&.month&.iso8601 : nil,
        settings: reasons.include?("specialty_without_sigtap")
      }
    end

    def unit_id(reasons, request, performer_unit_id, cnes)
      return request.requester_unit_id if reasons.include?("requester_unit_without_cnes")

      cnes ? performer_unit_id : nil
    end

    # O horário faltado do documento que o envio montaria (o primeiro passo,
    # senão o desejado), se ele é uma falta; senão nil. Só para a linha parada
    # por executante sem CNES (poucas): lê os fatos como o envio.
    def absence_slot(sync, request)
      settings = RegulationRndsSetting.current
      target = sync.pending_steps.first || RndsSync.target(request, settings: settings)
      return nil if target == :none

      facts = RiraFacts.for(request: request, settings: settings, credential: nil)
      code, at = RiraBundle.situation(target, facts)
      code == RndsStatus::ABSENCE ? RiraBundle.absence_slot(facts, at) : nil
    end

    private_class_method :unit_id, :absence_slot
  end
end
