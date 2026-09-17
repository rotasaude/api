# Base dos controllers da API de manutenção (maintenance-api.*).
#
# NÃO herda de ApplicationController: não há cidade no host, e CityResolution
# devolveria 404. Espelha Operators::BaseController, inclusive na ordem: o host
# é checado ANTES da autenticação, para host errado receber 404 e nunca 401.
module Maintenance
  class BaseController < ActionController::API
    include ActionController::Cookies

    before_action :require_maintenance_host

    include MaintainerAuthentication

    private

    def require_maintenance_host
      head :not_found unless CityCatalog.maintenance_api_host?(request.host)
    end
  end
end
