# app/services/signatures/oauth_states.rb
# State do OAuth com o PSC (ADR 0032; spec §10). O valor que viaja é um token
# assinado { c: cidade, s: id da linha } — a cidade do token tem de ser a do
# host que recebe o callback; a linha, no banco da cidade, guarda o code_verifier (PKCE)
# cifrado, o usuário, o propósito e o uso único. O token não leva o verifier.
module Signatures
  module OauthStates
    PURPOSE = :signature_oauth_state
    SIGNATURE_TTL = 1.day # a validade de USO é a da linha (10 min); esta só separa forjado de vencido
    RETURN_TO = %r{\A/(?:[^/\\\s][^\\\s]{0,198})?\z} # sem barra invertida: /\host vira //host no navegador
    MAX_STATE = 1024

    Issued = Data.define(:state, :verifier, :challenge, :row) do
      def inspect = "#<Signatures::OauthStates::Issued purpose=#{row.purpose}>"
      alias_method :to_s, :inspect

      def pretty_print(pp) = pp.text(inspect)
    end

    module_function

    def issue!(user:, purpose:, provider:, return_to: nil, request_ids: [], city: Current.city, now: Time.current)
      verifier = SecureRandom.urlsafe_base64(48)
      row = SignatureOauthState.create!(user_id: user.id, purpose: purpose, provider: provider, code_verifier: verifier,
                                        request_ids: request_ids, return_to: safe_return_to(return_to),
                                        expires_at: now + SignatureOauthState::TTL, created_at: now)
      state = verifier_service.generate({ "c" => city.slug, "s" => row.id }, purpose: PURPOSE, expires_in: SIGNATURE_TTL)
      Issued.new(state: state, verifier: verifier, challenge: challenge(verifier), row: row)
    end

    def challenge(verifier) = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)

    def safe_return_to(value) = value.is_a?(String) && value.match?(RETURN_TO) ? value : "/"

    def consume(state, user:, now: Time.current)
      payload = decode(state)
      return Result.fail(:invalid_state) unless payload && payload["c"] == Current.city&.slug && payload["s"].is_a?(String)

      SignatureOauthState.transaction do
        row = SignatureOauthState.lock.find_by(id: payload["s"])
        next Result.fail(:invalid_state) unless row && row.user_id == user.id && row.consumed_at.nil?

        row.update!(consumed_at: now)
        # O dono do state recebe o return_to também no vencido (contrato §13).
        next Result.fail(:authorization_expired, details: { return_to: row.return_to }) if row.expires_at <= now

        Result.ok(state: row)
      end
    end

    def decode(state)
      return nil unless state.is_a?(String) && state.present? && state.size <= MAX_STATE

      payload = verifier_service.verified(state, purpose: PURPOSE)
      payload.is_a?(Hash) ? payload : nil
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ArgumentError
      nil
    end

    def verifier_service = Rails.application.message_verifier("signature_oauth_state")
  end
end
