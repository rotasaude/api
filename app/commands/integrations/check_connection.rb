# app/commands/integrations/check_connection.rb
# Testa a credencial da cidade (ADR 0028; spec 2026-10-05 §3.3): LEDI = login
# no PEC da cidade; CADSUS = consulta de saúde do serviço. Grava o resultado com
# uma mensagem NOSSA — nunca o corpo da resposta nem a mensagem da exceção.
# Reasons: :unknown_kind, :credential_missing.
module Integrations
  module CheckConnection
    module_function

    # O PecClient só mapeia parte dos erros de rede; o resto também é "inalcançável",
    # nunca com o texto da exceção (que pode trazer URL).
    EXTRA_NETWORK_ERRORS = [ Net::WriteTimeout, Net::ProtocolError, Errno::EPIPE, Errno::ENETUNREACH ].freeze

    def call(kind:, city:)
      return Result.fail(:unknown_kind) unless IntegrationCredential::KINDS.include?(kind)

      credential = IntegrationCredential.find_by(kind: kind)
      return Result.fail(:credential_missing) unless credential

      status, message = kind == "ledi" ? check_ledi(city, credential) : check_cadsus(city)
      credential.update!(last_check_at: Time.current, last_check_status: status, last_check_message: message)
      Result.ok(credential: credential)
    end

    def check_ledi(city, credential)
      pec_url = Platform::Features.settings(city)[:pec_url]
      return [ "error", "Endereço do PEC não definido pelo operador" ] if pec_url.blank?

      Ledi::PecClient.new(base_url: pec_url, username: credential.username, password: credential.password).login
      [ "ok", "Login no PEC aceito" ]
    rescue Ledi::PecClient::Unauthorized
      [ "unauthorized", "O PEC recusou usuário ou senha" ]
    rescue Ledi::PecClient::Unreachable
      [ "unreachable", "PEC inalcançável" ]
    rescue Ledi::PecClient::Failed => e
      [ "error", e.status.between?(200, 299) ? "O PEC respondeu #{e.status} sem sessão" : "O PEC respondeu #{e.status}" ]
    rescue *EXTRA_NETWORK_ERRORS
      [ "unreachable", "PEC inalcançável" ]
    rescue URI::InvalidURIError
      [ "error", "Endereço do PEC inválido" ]
    end

    def check_cadsus(city)
      Cadsus::Client.for(city).health_check
      [ "ok", "CADSUS respondeu" ]
    rescue Cadsus::Unauthorized
      [ "unauthorized", "O CADSUS recusou a credencial" ]
    rescue Cadsus::Unavailable
      [ "unreachable", "CADSUS inalcançável" ]
    end
  end
end
