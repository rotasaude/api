# app/commands/integrations/check_connection.rb
# Testa a credencial da cidade (ADR 0028; spec 2026-10-05 §3.3): LEDI = login
# no PEC da cidade; CADSUS = consulta de saúde do serviço. Grava o resultado com
# uma mensagem NOSSA — nunca o corpo da resposta nem a mensagem da exceção.
# A bnafar testa a credencial do ambiente em uso (Q9): token novo do jwtauth.
# Reasons: :unknown_kind, :credential_missing.
module Integrations
  module CheckConnection
    module_function

    # O PecClient só mapeia parte dos erros de rede; o resto também é "inalcançável",
    # nunca com o texto da exceção (que pode trazer URL).
    EXTRA_NETWORK_ERRORS = [ Net::WriteTimeout, Net::ProtocolError, Errno::EPIPE, Errno::ENETUNREACH ].freeze

    def call(kind:, city:)
      return Result.fail(:unknown_kind) unless IntegrationCredential::KINDS.include?(kind)

      credential = IntegrationCredential.in_use(Bnafar::Environment.current).find_by(kind: kind)
      return Result.fail(:credential_missing) unless credential

      status, message = case kind
      when "ledi" then check_ledi(city, credential)
      when "rnds", "rnds_regulation" then check_rnds(city, credential)
      when "bnafar" then check_bnafar(city, credential)
      when "cadsus" then check_cadsus(city)
      else raise ArgumentError, "tipo de integração sem teste de conexão"
      end
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
    rescue Ledi::PecClient::InvalidUrl
      [ "error", "Endereço do PEC inválido" ]
    rescue Ledi::PecClient::Unreachable
      [ "unreachable", "PEC inalcançável" ]
    rescue Ledi::PecClient::Failed => e
      [ "error", e.status.between?(200, 299) ? "O PEC respondeu #{e.status} sem sessão" : "O PEC respondeu #{e.status}" ]
    rescue *EXTRA_NETWORK_ERRORS
      [ "unreachable", "PEC inalcançável" ]
    rescue URI::InvalidURIError
      [ "error", "Endereço do PEC inválido" ]
    end

    # O PFX abre e não venceu (local); depois pede o token de verdade ao EHR-AUTH
    # (o simulado, com rnds_mock). Mensagens nossas: nunca a da exceção.
    def check_rnds(city, credential)
      problem = Integrations::SetCredential.certificate_problem(credential.pfx_bytes, credential.pfx_password)
      return [ "error", problem == :certificate_expired ? "Certificado vencido" : "Certificado inválido" ] if problem

      Rnds::Client.for(city, kind: credential.kind).token!(fresh: true)
      [ "ok", "Token da RNDS emitido" ]
    rescue Rnds::Errors::NotConfigured
      [ "error", "RNDS não configurada pela plataforma" ]
    rescue Rnds::Errors::Unauthorized
      [ "unauthorized", "A RNDS recusou o certificado" ]
    rescue Rnds::Errors::Unavailable
      [ "unreachable", "RNDS inalcançável" ]
    end

    # Pede um token novo ao jwtauth (o simulado, com bnafar_mock). Mensagens
    # nossas: nunca a da exceção nem o corpo da resposta.
    def check_bnafar(city, credential)
      Bnafar::Client.for(city, environment: credential.environment).token!(fresh: true)
      [ "ok", "Token do SI-BNAFAR emitido" ]
    rescue Bnafar::Errors::NotConfigured
      [ "error", "SI-BNAFAR não configurado pela plataforma" ]
    rescue Bnafar::Errors::Unauthorized
      [ "unauthorized", "O SI-BNAFAR recusou usuário ou senha" ]
    rescue Bnafar::Errors::Unavailable
      [ "unreachable", "SI-BNAFAR inalcançável" ]
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
