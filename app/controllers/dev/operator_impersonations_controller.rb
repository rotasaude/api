# GET /dev/impersonate_operator — abre sessão de operador no console, SEM senha
# e SEM TOTP, e redireciona para o console. Ferramenta de development, ligada à
# tela de manutenção (GET /maintenance).
#
# ESTE É O IMPERSONATE MAIS FORTE DO SISTEMA, e o desenho reflete isso. No lado
# da cidade, o atalho pula uma senha de uma conta que nem MFA tem. Aqui ele pula
# o SEGUNDO FATOR — a sessão de operador nasce pendente e só autentica com
# mfa_verified_at carimbado, que é precisamente o que o TOTP faz. E o console é
# de onde se provisiona cidade, se registra canal e se EMITE GRANT para entrar
# em qualquer cidade.
#
# TRÊS GUARDAS, contra duas do impersonate de cidade:
#   1. a rota não é desenhada fora de development (config/routes.rb);
#   2. require_console_host, herdado de Operators::BaseController — host que não
#      seja admin.* recebe 404 antes de qualquer coisa;
#   3. development_only? na própria ação.
#
# Herda de Operators::BaseController de propósito: ele é ActionController::API
# direto, NÃO ApplicationController, porque admin.* é rótulo reservado e
# CityResolution devolveria 404 ali. A herança traz a guarda de host de graça.
#
# AUDITORIA — dois eventos, decisão do usuário. O challenge_totp legítimo carimba
# mfa_verified_at e audita operator.login na MESMA transação, de propósito, para
# não existir sessão sem auditoria; carimbar aqui sem auditar produziria
# exatamente o estado que aquela transação existe para impedir. Mas auditar só
# operator.login faria a trilha AFIRMAR um login com TOTP que não houve — e
# trilha que mente é pior que trilha ausente. Por isso os dois: operator.login
# para a sessão constar como qualquer outra, e operator.impersonated para que
# ninguém confunda atalho de dev com login real.
module Dev
  class OperatorImpersonationsController < Operators::BaseController
    allow_unauthenticated_operator_access only: :create
    before_action :require_development

    def create
      operator = DevImpersonation.operator
      return head :not_found if operator.nil?

      session = start_pending_operator_session_for(operator)
      return head :unprocessable_entity unless verify_without_totp(session)

      Current.operator_session = session
      redirect_to console_url, allow_other_host: true
    end

    private

    # Espelha o challenge_totp real: update_all condicional a mfa_verified_at nil
    # (nada a carimbar duas vezes) e auditoria dentro da mesma transação, tudo ou
    # nada. TTL é o mesmo OPERATOR_SESSION_TTL de 12 h do login legítimo — o
    # atalho não ganha comportamento próprio, que depois confundiria quem
    # investigasse uma sessão.
    def verify_without_totp(session)
      now = Time.current

      PlatformRecord.transaction do
        stamped = OperatorSession.where(id: session.id, mfa_verified_at: nil)
                                 .update_all(mfa_verified_at: now, updated_at: now)
        next false unless stamped == 1

        Platform.audit("operator.login", operator_id: session.operator_id, operator_session_id: session.id)
        Platform.audit("operator.impersonated", operator_id: session.operator_id, operator_session_id: session.id)
        session.assign_attributes(mfa_verified_at: now)
        true
      end
    end

    def console_url
      ENV.fetch("ALLOWED_ORIGINS", "http://admin.localhost:5174").split(",").first.to_s.strip + "/admin/"
    end

    def require_development
      head :not_found unless development_only?
    end

    # Método próprio, como no impersonate de cidade, para o spec de arquitetura
    # provar esta guarda sem a rota existir.
    def development_only?
      Rails.env.development?
    end
  end
end
