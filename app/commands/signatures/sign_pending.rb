# app/commands/signatures/sign_pending.rb
# Uma tentativa de assinar um pedido (ADR 0032; spec §5). FOR UPDATE SKIP
# LOCKED: se o lote (ou outro job) já trava o pedido, este sai sem esperar a
# chamada ao PSC dele (Review Focus 1). Chame dentro da transação da cidade.
# Falha deixa o pedido pending com o motivo (o status `failed` nunca sai daqui).
module Signatures
  module SignPending
    MAX_ATTEMPTS = 3

    module_function

    def call(request_id:, now: Time.current, signer: Signer.client, env: Rails.env)
      request = SignatureRequest.lock("FOR UPDATE SKIP LOCKED").find_by(id: request_id)
      return :skipped unless request&.pending?

      unless Gate.usable?(Current.city)
        ToPaper.call(request, reason_code: "feature_disabled", now: now)
        return :returned_to_paper
      end

      certificate = SignerCertificate.active.find_by(user_id: request.author_user_id)
      return park(request, "no_session", now) unless certificate

      reason = CertificateRules.reason(certificate, now: now)
      return park(request, reason, now) if reason

      session = SignatureSession.usable_for(request.author_user_id, now: now)
      unless session
        return park(request, SignatureSession.lapsed?(request.author_user_id, now: now) ? "session_expired" : "no_session", now)
      end

      outcome = Signing.call(requests: [ request ], access_token: session.access_token, certificate: certificate, now: now,
                             signer: signer, env: env)
      return :signed if outcome.signed.any?

      settle(request, outcome.failed.sole.last, outcome.final.include?(request.id), now)
    rescue Psc::Unauthorized
      session&.update!(status: "expired")
      park(request, "session_expired", now)
    rescue Psc::Unavailable
      retry_later(request, "provider_unavailable", now)
    rescue Psc::Rejected
      park(request, "provider_rejected", now)
    rescue Signer::Unavailable
      retry_later(request, "signer_unavailable", now)
    end

    def settle(request, reason, final, now)
      !final && SignatureRequest::TRANSIENT_REASONS.include?(reason) ? retry_later(request, reason, now) : park(request, reason, now)
    end

    def park(request, reason, now)
      Park.call(request, reason, now: now)
      :pending
    end

    def retry_later(request, reason, now)
      Park.call(request, reason, transient: true, now: now)
      request.attempts < MAX_ATTEMPTS ? :retry : :pending
    end
    private_class_method :settle, :park, :retry_later
  end
end
