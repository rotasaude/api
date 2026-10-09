# app/commands/signatures/start_session.rb
# Pede ao PSC a sessão do turno (ADR 0032; spec §5): escopo signature_session,
# 12 h pedidas (o PSC pode conceder menos; teto de 7 dias do ITI para PF).
# O PSC do certificado precisa continuar habilitado para a cidade (D6).
module Signatures
  module StartSession
    LIFETIME = SignatureSession::MAX_LIFETIME

    module_function

    def call(user:, return_to:)
      certificate = SignerCertificate.active.find_by(user_id: user.id)
      return Result.fail(:certificate_not_linked) unless certificate
      return Result.fail(:invalid_provider) unless Providers.configured?(certificate.provider, city: Current.city)

      cpf = user.professional&.cpf
      return Result.fail(:professional_cpf_missing) if cpf.blank?

      issued = OauthStates.issue!(user: user, purpose: "session", provider: certificate.provider, return_to: return_to)
      url = Psc::Client.for(certificate.provider).authorize_url(
        state: issued.state, challenge: issued.challenge, scope: SignatureSession::SCOPE, login_hint: cpf,
        redirect_uri: Providers.redirect_uri(Current.city), lifetime: LIFETIME.to_i
      )
      Result.ok(authorize_url: url)
    end
  end
end
