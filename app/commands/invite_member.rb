class InviteMember
  def self.call(email:, role:, municipality_id:, invited_by:, expires_in: 7.days)
    new(email: email, role: role, municipality_id: municipality_id, invited_by: invited_by, expires_in: expires_in).call
  end

  def initialize(email:, role:, municipality_id:, invited_by:, expires_in:)
    @email, @role, @municipality_id, @invited_by, @expires_in =
      email, role, municipality_id, invited_by, expires_in
  end

  def call
    inv = nil
    ApplicationRecord.connected_to(role: :admin) do
      inv = Invitation.create!(
        email: @email.downcase,
        role: @role,
        municipality_id: @municipality_id,
        token: SecureRandom.urlsafe_base64(32),
        invited_by: @invited_by,
        expires_at: @expires_in.from_now
      )
    end
    # publica conforme escopo
    if @municipality_id
      DomainEvents.publish("user.invited", email: @email, role: @role, invitation_id: inv.id)
    else
      Platform.audit("user.invited", email: @email, role: @role, invitation_id: inv.id)
    end
    Result.ok(invitation: inv)
  rescue ActiveRecord::RecordInvalid => e
    Result.fail(:invalid, message: e.record.errors.full_messages.join(", "))
  end
end
