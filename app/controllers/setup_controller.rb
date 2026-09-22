# Endpoints HTTP do "setup" — invocam commands do Phase 4/6.
# Ver ADR-0012 (memberships/authz) e ADR-0013 (provisionamento).
#
# Disposição no mundo por cidade (lote 5b; destino final nos Planos 3B/4):
#   - accept_invitation, invite_member, list_memberships, revoke_membership e
#     deactivate_user agem SOBRE dados da cidade — convites, usuários e
#     memberships moram no banco dela —, então resolvem a cidade pelo host como
#     qualquer controller, e a sessão é a da cidade;
#   - deactivate_user segue exigindo operador; nenhum usuário de cidade é
#     operador (User#operator?), então responde 403 até o grant de operador
#     do Plano 3B;
#   - provisionar cidade não é mais daqui: é POST /cities no console de
#     plataforma (Operators::CitiesController, Plano 4).
#
# Aceite de convite (POST /setup/accept_invitation) é PÚBLICO (token é cred).
class SetupController < ApplicationController
  include Authentication
  include ScalarParams
  include MfaStepUp

  allow_unauthenticated_access only: %i[accept_invitation]

  # Fluxo público token-as-credential — mesmo teto de sessions/passwords, para
  # não deixar superfície de brute-force sem limite. Só na ação pública.
  rate_limit to: 10, within: 3.minutes, only: %i[accept_invitation],
             with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

  # POST /setup/invitations
  # body: { email, role }
  def invite_member
    return head(:forbidden) unless can_manage_members?

    email = params.expect(:email)
    role = params.expect(:role)
    return require_step_up! if privileged_role?(role) && !reauthenticated_recently?

    result = InviteMember.call(
      email: email,
      role:  role,
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
      token: params.expect(:token),
      password: params.expect(:password)
    )
    if result.ok?
      user = result.payload[:user]
      start_new_session_for(user)
      render json: { id: user.id, email_address: user.email_address }, status: :created
    else
      render json: { error: result.reason.to_s, message: result.message }, status: :unprocessable_entity
    end
  end

  # POST /setup/memberships
  # body: { user_id, role } — só municipal_admin (spec de assinaturas §3). O
  # command recusa o resto: papel desconhecido, já concedido, usuário inativo.
  def grant_role
    return head(:forbidden) unless can_manage_members?

    user_id = params.expect(:user_id)
    role = params.expect(:role)
    return require_step_up! if privileged_role?(role) && !reauthenticated_recently?

    result = GrantRole.call(user_id: user_id, role: role, by: current_user)
    if result.ok?
      m = result.payload[:membership]
      render json: { id: m.id, user_id: m.user_id, role: m.role, granted_at: m.granted_at.iso8601 }, status: :created
    else
      render json: { error: result.reason.to_s, message: result.message }.compact,
             status: result.reason == :forbidden ? :forbidden : :unprocessable_entity
    end
  end

  # POST /setup/memberships/:id/revoke
  def revoke_membership
    membership = Membership.find_by(id: params[:id])
    return head(:not_found) unless membership
    return head(:forbidden) unless can_manage_members?
    return require_step_up! if privileged_role?(membership.role) && !reauthenticated_recently?

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

    rows = Membership.active.joins(:user).where(users: { deactivated_at: nil }).includes(:user).map do |m|
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

  # Spec do dashboard §4.1: conceder ou revogar um papel de
  # Membership::PRIVILEGED_ROLES exige verificação recente de TOTP — quem
  # decide quem revisa protocolo decide quem aprova protocolo clínico, e o
  # login da cidade é só senha. Papel comum (viewer, author, publisher) segue
  # sem step-up: o §8 do spec de assinaturas mudou só para os privilegiados.
  def privileged_role?(role)
    Membership::PRIVILEGED_ROLES.include?(role.to_s)
  end
end
