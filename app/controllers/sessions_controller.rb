# Sessões de usuário DA CIDADE — JSON-only (API). Ver ADR-0011.
#
# Roda dentro da conexão da cidade do host (CityResolution): usuário e sessão são
# procurados no banco dessa cidade, então o cookie de uma cidade não autentica
# na vizinha. Operador de plataforma NÃO loga aqui — ver
# Operators::SessionsController, no host admin.*.
#
#   POST   /session   { email_address, password }  → 201 + set-cookie
#   GET    /session                                 → 200 | 401
#   DELETE /session                                 → 204 + clear-cookie
class SessionsController < ApplicationController
  include Authentication

  allow_unauthenticated_access only: %i[create govbr_callback]

  # Operador dentro da cidade (grant, Plano 3B) vê e encerra a própria sessão; nada mais.
  allow_operator_grant_access only: %i[show destroy]

  rate_limit to: 10, within: 3.minutes, only: %i[create govbr_callback],
             with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

  def create
    user = Authenticator.password(email: params[:email_address], password: params[:password])
    return render(json: { error: "invalid_credentials" }, status: :unauthorized) unless user

    start_new_session_for(user)
    render json: serialize(user), status: :created
  end

  # GET /auth/govbr/callback?code=…&state=…  (ADR-0011 gov.br seam)
  #
  # Provisório: roda na cidade do host, como as demais ações — a identidade gov.br
  # e a sessão são gravadas no banco dessa cidade. O callback único em auth.*,
  # resolvendo a cidade pelo `state` com grant assinado, é do Plano 3B.
  #
  # state opcional aqui — backend não armazena state em sessão (API JSON).
  # Frontend SPA é quem gera/verifica state via storage local + envia ao
  # gov.br. Este endpoint só completa o exchange e cria a sessão.
  def govbr_callback
    user = Authenticator.govbr(code: params[:code])
    return render(json: { error: "govbr_unauthenticated" }, status: :unauthorized) unless user

    start_new_session_for(user)
    render json: serialize(user), status: :created
  rescue Authenticator::GovBr::IntegrationError => e
    Rails.logger.error("[govbr_callback] #{e.class}: #{e.message}")
    render json: { error: "govbr_integration_error" }, status: :bad_gateway
  end

  def destroy
    terminate_session
    head :no_content
  end

  # GET /session — quem está autenticado agora (útil para a UI inicializar).
  def show
    return render(json: serialize_operator_grant(Current.session)) if Current.session.operator_grant?
    return head :unauthorized unless current_user

    render json: serialize(current_user)
  end

  private

  # Sessão de operador aberta por grant (Plano 3B): mesmo formato do SessionUser;
  # operador não tem membership na cidade.
  def serialize_operator_grant(session)
    operator = session.operator
    {
      id: operator.id,
      email_address: operator.email_address,
      mfa_enrolled: operator.mfa_enrolled?,
      operator: true,
      mfa_verified_at: nil,
      memberships: []
    }
  end

  def serialize(user)
    {
      id: user.id,
      email_address: user.email_address,
      mfa_enrolled: user.mfa_enrolled?,
      # Chave do contrato que dashboard e admin já leem. Usuário de cidade nunca
      # é operador; operador loga no console (Operators::SessionsController).
      operator: false,
      mfa_verified_at: Current.session&.mfa_verified_at&.iso8601,
      memberships: serialize_memberships(user)
    }
  end

  # Memberships ativos na cidade do host. As chaves municipality_* seguem o
  # contrato que dashboard e admin já leem (apps/*/src/lib/api.ts), mas os
  # valores vêm da cidade resolvida — a chave de id carrega o slug. Renomear o
  # contrato é dos frontends (Plano 6).
  def serialize_memberships(user)
    city = Current.city
    user.memberships.active.map do |m|
      {
        municipality_id: city.slug,
        municipality_name: city.name,
        municipality_uf: city.uf,
        role: m.role
      }
    end
  end
end
