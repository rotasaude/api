# Base de TODOS os controllers. Atenção:
#   - NÃO incluir Authentication aqui — webhooks, reports e protocolos
#     têm caminhos de auth próprios (signed token, header de Author).
#     Cada controller que precisa de sessão inclui Authentication
#     explicitamente (SessionsController, Admin::Api::BaseController).
#   - ActionController::Cookies é necessário para que `cookies.signed`
#     funcione em API mode (config.api_only = true).
#   - TenantScopedRequest adiciona around_action :within_tenant (ADR-0019).
#     Controllers sem resolução de município aplicam skip_tenant_scope.
class ApplicationController < ActionController::API
  include ActionController::Cookies
  include TenantScopedRequest
end
