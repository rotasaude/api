# GET /dev/impersonate — abre uma sessão de municipal_admin da cidade do host,
# SEM credencial, e redireciona para o dashboard dela. Ferramenta de
# development, ligada à tela de manutenção (GET /maintenance).
#
# POR QUE NO HOST DA CIDADE, e não na tela: o cookie de sessão é host-only —
# Authentication#write_session_cookie nunca seta `domain:`, por regra do §5 da
# spec. Um cookie gravado em `localhost` (onde a tela vive) não é enviado para
# `curitiba.localhost`. Já um gravado em `curitiba.localhost:3030` VALE em
# `curitiba.localhost:5175`, porque cookie ignora porta. Por isso o link sai no
# host da cidade e a ação roda aqui, dentro do CityResolution que ele dispara.
#
# DUAS GUARDAS, de propósito. A rota não é desenhada fora de development
# (config/routes.rb), e a ação checa de novo. Na tela de manutenção uma guarda
# basta; aqui não, porque a consequência de a primeira falhar mudou de ordem:
# lá alguém lê configuração, aqui alguém entra como administrador de qualquer
# cidade, sem senha e sem MFA. Defesa em profundidade se paga quando o custo do
# vazamento muda de grandeza, não por princípio geral.
#
# Reusa start_new_session_for — a MESMA máquina do login por senha. Não existe
# caminho de sessão paralelo aqui: o que esta ação pula é a verificação de
# credencial, nada mais.
module Dev
  class ImpersonationsController < ApplicationController
    include Authentication

    allow_unauthenticated_access only: :create
    before_action :require_development

    def create
      user = DevImpersonation.target
      return head :not_found if user.nil?

      start_new_session_for(user)
      redirect_to CityPublicUrl.dashboard(Current.city), allow_other_host: true
    end

    private

    def require_development
      head :not_found unless development_only?
    end

    # Método próprio, e não `Rails.env.development?` inline, para o spec de
    # arquitetura conseguir provar esta segunda guarda sem a rota existir.
    def development_only?
      Rails.env.development?
    end
  end
end
