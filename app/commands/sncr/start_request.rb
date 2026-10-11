# Começa o pedido de números (ADR 0034; contrato §4; Desvios 1–4): só quem
# tem inscrição em CRM/CRO (o SNCR não aceita outro conselho para humanos), no
# máximo 3 pedidos por tipo no mês, com o SNCR da cidade (real ou simulado).
# O state de uso único é o do 19b (signature_oauth_states, propósito
# sncr_<kind>); o code_verifier da linha nunca sai (o SNCR não usa PKCE nosso).
module Sncr
  module StartRequest
    COUNCILS = %w[CRM CRO].freeze

    module_function

    def call(user:, kind:, return_to:, now: Time.current)
      return Result.fail(:invalid_content, details: { field: "kind" }) unless Client::KINDS.key?(kind)
      return Result.fail(:cbo_not_allowed) unless COUNCILS.include?(user.professional&.council)
      return Result.fail(:monthly_limit_reached) if Stock.requests_this_month(user: user, kind: kind, now: now) >= Stock::MONTHLY_LIMIT

      client = Client.for(Current.city)
      issued = Signatures::OauthStates.issue!(user: user, purpose: "sncr_#{kind}", provider: client.provider,
                                              return_to: return_to, now: now)
      Result.ok(authorize_url: client.login_url(client_url: callback_url(Current.city), state: issued.state), state: issued.state)
    rescue Client::Unavailable
      Result.fail(:sncr_unavailable)
    end

    def callback_url(city) = "#{CityPublicUrl.dashboard(city)}sncr/callback"
  end
end
