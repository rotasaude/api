# app/commands/signatures/open_session.rb
# Grava a sessão do turno (ADR 0032; spec §5; Desvio 11). O certificado é
# relido do PSC e passa pelas conferências do vínculo (renovado vira o ativo).
module Signatures
  module OpenSession
    module_function

    def call(user:, provider:, client:, token:, now: Time.current)
      return Result.fail(:authorization_denied) unless token.scope.to_s.split.include?(SignatureSession::SCOPE)
      return Result.fail(:authorization_expired) unless token.expires_in.to_i.positive?

      accepted = AcceptCertificate.call(user: user, provider: provider, entries: client.certificates(token.access_token), now: now)
      return accepted if accepted.failure?

      ApplicationRecord.transaction do
        SignatureSession.active.where(user_id: user.id).lock.each do |previous|
          previous.update!(status: previous.expires_at > now ? "revoked" : "expired")
        end
        session = SignatureSession.create!(
          user: user, signer_certificate: accepted.payload[:certificate], provider: provider,
          access_token: token.access_token, scope: SignatureSession::SCOPE, started_at: now,
          expires_at: now + [ token.expires_in.to_i.seconds, SignatureSession::MAX_LIFETIME ].min
        )
        DomainEvents.publish("signature.session_opened", session_id: session.id, user_id: user.id, provider: provider)
        Result.ok(record: session)
      end
    end
  end
end
