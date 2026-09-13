# Endpoints HTTP do "setup" — invocam commands do Phase 4/6.
# Ver ADR-0012 (memberships/authz) e ADR-0013 (provisionamento).
#
# Disposição no mundo por cidade (lote 5b; destino final nos Planos 3/4):
#   - accept_invitation, invite_member, list_memberships, revoke_membership e
#     deactivate_user agem SOBRE dados da cidade — convites, usuários e
#     memberships moram no banco dela —, então resolvem a cidade pelo host como
#     qualquer controller, e a sessão é a da cidade;
#   - deactivate_user segue exigindo operador; nenhum usuário de cidade é
#     operador (User#operator?), então responde 403 até o grant do Plano 3;
#   - provision_municipality é ação de operador sobre o catálogo, servida no
#     host de plataforma: pula a resolução de cidade. Sem autenticação de
#     operador na plataforma (Plano 3) nem provisionamento de banco (Plano 4),
#     responde 501 sem tocar dado nenhum.
#
# Aceite de convite (POST /setup/accept_invitation) é PÚBLICO (token é cred).
class SetupController < ApplicationController
  skip_city_resolution only: %i[provision_municipality]

  include Authentication

  # provision_municipality não autentica porque não faz nada além de responder
  # 501: não há sessão de operador resolvível fora de uma cidade até o Plano 3.
  allow_unauthenticated_access only: %i[accept_invitation provision_municipality]

  # Fluxo público token-as-credential — mesmo teto de sessions/passwords, para
  # não deixar superfície de brute-force sem limite. Só na ação pública.
  rate_limit to: 10, within: 3.minutes, only: %i[accept_invitation],
             with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

  # POST /setup/municipalities — desligado até o Plano 3 (autenticação de
  # operador na plataforma) e o Plano 4 (POST /setup/cities, provisionamento em
  # duas fases). O command ProvisionMunicipality segue utilizável para uma cidade
  # já registrada e servível, fora do HTTP.
  def provision_municipality
    render json: {
      error: "provisioning_unavailable",
      message: "provisionamento de cidade passa para a plataforma (Planos 3 e 4)"
    }, status: :not_implemented
  end

  # POST /setup/invitations
  # body: { email, role }
  def invite_member
    return head(:forbidden) unless can_manage_members?

    result = InviteMember.call(
      email: params.require(:email),
      role:  params.require(:role),
      invited_by: current_user
    )
    if result.ok?
      inv = result.payload[:invitation]
      render json: { id: inv.id, email: inv.email, role: inv.role, expires_at: inv.expires_at.iso8601 }, status: :created
    else
      render json: { error: result.reason.to_s, message: result.message }, status: :unprocessable_entity
    end
  end

  # POST /setup/accept_invitation
  # body: { token, password }
  # PUBLIC — token é a credencial.
  def accept_invitation
    result = AcceptInvitation.call(
      token: params.require(:token),
      password: params.require(:password)
    )
    if result.ok?
      user = result.payload[:user]
      start_new_session_for(user)
      render json: { id: user.id, email_address: user.email_address }, status: :created
    else
      render json: { error: result.reason.to_s, message: result.message }, status: :unprocessable_entity
    end
  end

  # POST /setup/memberships/:id/revoke
  def revoke_membership
    membership = Membership.find_by(id: params[:id])
    return head(:not_found) unless membership
    return head(:forbidden) unless can_manage_members?

    result = RevokeMembership.call(membership_id: membership.id, by: current_user)
    if result.ok?
      render json: { id: membership.id, revoked_at: membership.reload.revoked_at.iso8601 }, status: :ok
    else
      render json: { error: result.reason.to_s, message: result.message }, status: :unprocessable_entity
    end
  end

  # POST /setup/users/:id/deactivate
  def deactivate_user
    return head(:forbidden) unless current_user.operator?
    result = DeactivateUser.call(user_id: params[:id], by: current_user)
    if result.ok?
      user = result.payload[:user]
      render json: { id: user.id, deactivated_at: user.deactivated_at.iso8601 }, status: :ok
    else
      render json: { error: result.reason.to_s, message: result.message }, status: :unprocessable_entity
    end
  end

  # GET /setup/memberships
  def list_memberships
    return head(:forbidden) unless can_manage_members?

    rows = Membership.active.includes(:user).map do |m|
      {
        id: m.id,
        user: { id: m.user.id, email_address: m.user.email_address },
        role: m.role,
        granted_at: m.granted_at.iso8601
      }
    end
    render json: { data: rows }
  end

  private

  # municipal_admin DESTA cidade (o banco é o da cidade do host).
  def can_manage_members?
    current_user.has_role?("municipal_admin")
  end
end
