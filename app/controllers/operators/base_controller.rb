# Base dos controllers do console de plataforma (admin.*).
#
# NÃO herda de ApplicationController: não há cidade a resolver aqui, e
# CityResolution devolveria 404 para o host reservado admin.*. A autenticação é
# contra Operator/OperatorSession, no banco de plataforma — nunca contra
# User/Session de uma cidade.
module Operators
  class BaseController < ActionController::API
    include ActionController::Cookies

    # Defesa em profundidade: as rotas já exigem PlatformConsoleHost. Declarado
    # ANTES de OperatorAuthentication para rodar primeiro: host de cidade recebe
    # 404, nunca 401.
    before_action :require_console_host

    include OperatorAuthentication

    private

    def require_console_host
      head :not_found unless CityCatalog.console_host?(request.host)
    end
  end
end
