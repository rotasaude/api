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
    # (settings false) quando o motivo não tem atalho.
    def fix(sync, request)
      reasons = sync.blocked_reasons
      offer = request.current_authorization&.care_offer
      provider = offer&.care_provider || request.care_provider
      cbo = reasons.include?("performer_cbo_missing")
      cnes = reasons.include?("performer_without_cnes")
      {
        offer_id: cbo ? offer&.id : nil,
        provider_id: cbo || cnes ? provider&.id : nil,
        unit_id: unit_id(reasons, request, provider, cnes),
        offer_month: cbo ? offer&.month&.iso8601 : nil,
        settings: reasons.include?("specialty_without_sigtap")
      }
    end

    def unit_id(reasons, request, provider, cnes)
      return request.requester_unit_id if reasons.include?("requester_unit_without_cnes")

      cnes ? provider&.health_unit_id : nil
    end

    private_class_method :unit_id
  end
end
