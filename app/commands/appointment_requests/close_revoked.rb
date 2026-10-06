# Revogação (ADR 0029 §5.2; ADR 0026): o pedido de triagem ainda aberto (sem
# horário) ligado a triagens da conversa revogada — pela origem ou pela fusão —
# fecha como consent_revoked, a menos que outra triagem ligada a ele esteja numa
# conversa com consentimento ativo. O já marcado fica (o cidadão cancela se
# quiser). Chamado DENTRO da transação de RevokeConsent, depois de revogar.
module AppointmentRequests
  module CloseRevoked
    module_function

    def call(conversation:)
      triage_ids = conversation.triages.select(:id)
      linked = AppointmentRequestTriage.where(triage_id: triage_ids).select(:request_id)
      base = AppointmentRequest.where(kind: "triage", status: "open")
      requests = base.where(origin_triage_id: triage_ids).or(base.where(id: linked)).order(:id).lock.to_a
      requests.reject { |request| still_consented?(request, conversation) }.each do |request|
        Lifecycle.close!(request, reason: "consent_revoked")
      end
    end

    def still_consented?(request, conversation)
      triage_ids = [ request.origin_triage_id, *request.request_triages.pluck(:triage_id) ]
      Consent.where(revoked_at: nil, conversation_id: Triage.where(id: triage_ids).select(:conversation_id))
             .where.not(conversation_id: conversation.id).exists?
    end
  end
end
