# Sessões — JSON-only (API). Ver ADR-0011.
#
#   POST   /session   { email_address, password }  → 201 + set-cookie (não-operador)
#                                                  → 200 + mfa_required (operador)
#   POST   /session/challenge { session_id, code } → 200 + carimbas mfa_verified_at
#   DELETE /session                                 → 204 + clear-cookie
class SessionsController < ApplicationController
  include Authentication

  allow_unauthenticated_access only: %i[create challenge_totp govbr_callback]

  rate_limit to: 10, within: 3.minutes, only: %i[create challenge_totp govbr_callback],
             with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

  def create
    user = Authenticator.password(email: params[:email_address], password: params[:password])
    return render(json: { error: "invalid_credentials" }, status: :unauthorized) unless user

    if user.operator? && !user.mfa_enrolled?
      return render(json: { error: "mfa_enrollment_required" }, status: :forbidden)
    end

    session = start_new_session_for(user)

    if user.operator?
      # Operador exige TOTP toda vez (login, não step-up — ADR-0011).
      return render(json: { mfa_required: true, session_id: session.id }, status: :ok)
    end

    render json: serialize(user), status: :created
  end

  def challenge_totp
    session = Session.find_by(id: params[:session_id])
    return render(json: { error: "invalid_session" }, status: :unauthorized) unless session

    user = session.user
    if Mfa::Verify.call(user, code: params[:code])
      session.update!(mfa_verified_at: Time.current)
      cookies.signed.permanent[:session_id] = { value: session.id, httponly: true, same_site: :lax, secure: Rails.env.production? }
      render json: serialize(user), status: :ok
    else
      render json: { error: "invalid_code" }, status: :unauthorized
    end
  end

  # GET /auth/govbr/callback?code=…&state=…  (ADR-0011 gov.br seam)
  #
  # Provisório (Ruling R13): roda na cidade do host, como as demais ações — a
  # identidade gov.br e a sessão são gravadas no banco dessa cidade. O callback
  # único em auth.* resolvendo a cidade pelo `state`, com grant assinado, é do
  # Esboço A / Plano 3.
  #
  # state opcional aqui — backend não armazena state em sessão (API JSON).
  # Frontend SPA é quem gera/verifica state via storage local + envia ao
  # gov.br. Este endpoint só completa o exchange e cria a sessão.
  def govbr_callback
    user = Authenticator.govbr(code: params[:code])
    return render(json: { error: "govbr_unauthenticated" }, status: :unauthorized) unless user

    if user.operator? && !user.mfa_enrolled?
      return render(json: { error: "mfa_enrollment_required" }, status: :forbidden)
    end

    session = start_new_session_for(user)
    if user.operator?
      return render(json: { mfa_required: true, session_id: session.id }, status: :ok)
    end

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
    return head :unauthorized unless current_user
    render json: serialize(current_user)
  end

  private

  def serialize(user)
    {
      id: user.id,
      email_address: user.email_address,
      mfa_enrolled: user.mfa_enrolled?,
      operator: user.operator?,
      mfa_verified_at: Current.session&.mfa_verified_at&.iso8601,
      memberships: serialize_memberships(user)
    }
  end

  # Memberships ativos na cidade do host. As chaves municipality_* seguem o
  # contrato que dashboard e admin já leem (apps/*/src/lib/api.ts), mas os
  # valores vêm da cidade resolvida — a chave de id carrega o slug. Renomear o
  # contrato é dos frontends (Plano 3).
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
