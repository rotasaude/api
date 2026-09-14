# Base de TODOS os controllers. Atenção:
#   - NÃO incluir Authentication aqui — webhooks, reports e protocolos
#     têm caminhos de auth próprios (signed token, header de Author).
#     Cada controller que precisa de sessão inclui Authentication
#     explicitamente (SessionsController, Admin::Api::BaseController).
#   - ActionController::Cookies é necessário para que `cookies.signed`
#     funcione em API mode (config.api_only = true).
#   - CityResolution adiciona around_action :within_city: resolve a cidade
#     pelo host antes de qualquer query, e executa a ação dentro da conexão
#     daquela cidade. Controllers que não são servidos por subdomínio de
#     cidade aplicam skip_city_resolution (Webhooks::WhatsappController).
class ApplicationController < ActionController::API
  include ActionController::Cookies
  include CityResolution
end
