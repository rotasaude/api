# app/services/signatures/json.rb
# Formas do contrato do 19b (contrato §3–§5). O provider sai como gravado
# (inclusive `simulated`).
module Signatures
  module Json
    module_function

    def certificate(certificate, now: Time.current)
      { id: certificate.id, provider: certificate.provider, issuer: certificate.info.issuer_name,
        serial_number: certificate.serial_number, not_after: certificate.not_after.iso8601, status: certificate.status,
        expires_in_days: certificate.expires_in_days(now) }
    end

    def session(session)
      return { active: false } unless session

      { active: true, expires_at: session.expires_at.iso8601, provider: session.provider }
    end
  end
end
