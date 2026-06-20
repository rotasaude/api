# Endpoints HTTP do "setup" multi-tenant — invocam commands do Phase 4/6.
# Ver ADR-0023 (memberships/authz) e ADR-0024 (provisionamento).
#
# Authn: cookie de sessão (Authentication concern).
# Authz: por endpoint, ver each_action (operator para provision/deactivate;
#        municipal_admin para invite/revoke).
# Aceite de convite (POST /setup/accept_invitation) é PÚBLICO (token é cred).
class SetupController < ApplicationController
  # Setup é cross-tenant em ações de operador (provision/deactivate). Para
  # invite/revoke usa current_municipality via membership do user, mas a
  # resolução é feita aqui (não via TenantScopedRequest, que falharia para
  # operador sem header). Pular o around_action.
  skip_tenant_scope

  include Authentication

  allow_unauthenticated_access only: %i[accept_invitation]

  # POST /setup/municipalities
  # body: { name, slug, ibge_code, uf, channel: { phone_number_id, ... }, admin_email, terms: { body, version }, alert: [...], template: {...} }
  def provision_municipality
    return head(:forbidden) unless current_user.operator?

    result = ProvisionMunicipality.call(**provision_params, invited_by: current_user)
    if result.ok?
      muni = result.payload[:municipality]
      render json: { id: muni.id, name: muni.name, slug: muni.slug }, status: :created
    else
      render json: { error: result.reason.to_s, message: result.message }, status: :unprocessable_entity
    end
  end

  # POST /setup/invitations
  # body: { email, role, municipality_id }
  def invite_member
    muni_id = params[:municipality_id]
    return render(json: { error: "municipality_id_required" }, status: :unprocessable_entity) if muni_id.blank? && !current_user.operator?
    return head(:forbidden) unless can_manage_members?(muni_id)

    result = InviteMember.call(
      email: params.require(:email),
      role:  params.require(:role),
      municipality_id: muni_id,
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
    membership = ApplicationRecord.connected_to(role: :admin) { Membership.find_by(id: params[:id]) }
    return head(:not_found) unless membership
    return head(:forbidden) unless can_manage_members?(membership.municipality_id)

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

  # GET /setup/memberships?municipality_id=…
  def list_memberships
    muni_id = params[:municipality_id]
    return head(:forbidden) unless can_manage_members?(muni_id)

    rows = ApplicationRecord.connected_to(role: :admin) do
      scope = Membership.active.includes(:user)
      scope = scope.where(municipality_id: muni_id) if muni_id.present?
      scope.map do |m|
        {
          id: m.id,
          user: { id: m.user.id, email_address: m.user.email_address },
          municipality_id: m.municipality_id,
          role: m.role,
          granted_at: m.granted_at.iso8601
        }
      end
    end
    render json: { data: rows }
  end

  private

  def can_manage_members?(municipality_id)
    return true if current_user.operator?
    return false if municipality_id.blank?
    current_user.role_in?(municipality_id, role: "municipal_admin")
  end

  def provision_params
    {
      name:        params.require(:name),
      slug:        params.require(:slug),
      ibge_code:   params.require(:ibge_code),
      uf:          params[:uf],
      channel:     params.require(:channel).permit(:phone_number_id, :waba_id, :display_phone_number, :access_token).to_h.symbolize_keys,
      admin_email: params.require(:admin_email),
      terms:       params.require(:terms).permit(:version, :body).to_h.symbolize_keys,
      alert:       Array(params[:alert]).map { |a| ActionController::Parameters.new(a).permit(:channel, :destination, :escalation_order).to_h.symbolize_keys },
      template:    params[:template].present? ? params.require(:template).permit(:name, definition: {}).to_h.symbolize_keys : nil
    }
  end
end
