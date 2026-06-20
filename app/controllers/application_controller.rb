# Base de TODOS os controllers. Atenção:
#   - NÃO incluir Authentication aqui — webhooks, reports e protocolos
#     têm caminhos de auth próprios (signed token, header de Author).
#     Cada controller que precisa de sessão inclui Authentication
#     explicitamente (SessionsController, Admin::Api::BaseController).
#   - ActionController::Cookies é necessário para que `cookies.signed`
#     funcione em API mode (config.api_only = true).
class ApplicationController < ActionController::API
  include ActionController::Cookies
end
