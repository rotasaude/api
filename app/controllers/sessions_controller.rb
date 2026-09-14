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
#   POST   /session/grant   { token }                    → 201 (entrada por grant assinado, Plano 3B)
class SessionsController < ApplicationController
  include Authentication

  allow_unauthenticated_access only: %i[create govbr_callback grant]

  # Operador dentro da cidade (grant, Plano 3B) vê e encerra a própria sessão; nada mais.
  allow_operator_grant_access only: %i[show destroy]

  rate_limit to: 10, within: 3.minutes, only: %i[create govbr_callback grant],
             with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

  def create
    user = Authenticator.password(email: params[:email_address], password: params[:password])
    return render(json: { error: "invalid_credentials" }, status: :unauthorized) unless user

    start_new_session_for(user)
    render json: serialize(user), status: :created
  end

  # POST /session/grant { token } — entrada por grant assinado (spec §5, Plano 3B).
  # O grant de uma cidade não vale em outra, vale uma vez e por 60 s (CityGrants).
  def grant
    grant = CityGrants.redeem(token: params[:token], city: Current.city)
    return render_invalid_grant unless grant

    grant.kind == "operator" ? open_operator_grant_session(grant) : open_user_grant_session(grant)
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

  def render_invalid_grant
    render json: { error: "invalid_grant" }, status: :unauthorized
  end

  # Auditoria primeiro na PLATAFORMA, depois Session + evento na CIDADE (transação
  # da cidade). Sem transação comum aos dois bancos, a falha que sobra é o registro
  # de uma tentativa sem sessão — nunca uma sessão sem auditoria.
  def open_operator_grant_session(grant)
    operator = Operator.find_by(id: grant.subject_id)
    return render_invalid_grant unless operator&.active?

    Platform.audit("operator.city_access", city_id: Current.city.id, operator_id: operator.id)
    session = ApplicationRecord.transaction do
      Session.create!(operator_id: operator.id, user_agent: request.user_agent, ip_address: request.remote_ip).tap do |s|
        DomainEvents.publish("operator.city_access", operator_id: operator.id, session_id: s.id)
      end
    end
    Current.session = session
    write_session_cookie(session)
    render json: serialize_operator_grant(session), status: :created
  end

  def open_user_grant_session(grant)
    user = User.find_by(id: grant.subject_id)
    return render_invalid_grant unless user&.active?

    start_new_session_for(user)
    render json: serialize(user), status: :created
  end

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
