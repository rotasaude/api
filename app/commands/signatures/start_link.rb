# app/commands/signatures/start_link.rb
# Começa o vínculo (ADR 0032; spec §5): OAuth com PKCE, escopo
# single_signature, CPF do profissional como login_hint. Só PSC da cidade.
module Signatures
  module StartLink
    module_function

    def call(user:, provider:, return_to:)
      return Result.fail(:invalid_provider) unless provider.is_a?(String) && Providers.configured?(provider)

      cpf = user.professional&.cpf
      return Result.fail(:professional_cpf_missing) if cpf.blank?

      issued = OauthStates.issue!(user: user, purpose: "link", provider: provider, return_to: return_to)
      url = Psc::Client.for(provider).authorize_url(state: issued.state, challenge: issued.challenge, scope: "single_signature",
                                                    login_hint: cpf, redirect_uri: Providers.redirect_uri(Current.city))
      Result.ok(authorize_url: url)
    end
  end
end
