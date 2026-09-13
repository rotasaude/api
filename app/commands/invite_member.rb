# Convite de membro para a cidade da conexão corrente. user.invited — que leva o
# e-mail do convidado — vai para o domain_events DA CIDADE, que guarda quem
# acessa os dados dela; nunca para a plataforma (Ruling R18).
class InviteMember
  def self.call(email:, role:, invited_by:, expires_in: 7.days)
    new(email: email, role: role, invited_by: invited_by, expires_in: expires_in).call
  end

  def initialize(email:, role:, invited_by:, expires_in:)
    @email, @role, @invited_by, @expires_in = email, role, invited_by, expires_in
  end

  def call
    inv = nil
    ApplicationRecord.transaction do
      inv = Invitation.create!(
        email: @email.downcase,
        role: @role,
        token: SecureRandom.urlsafe_base64(32),
        invited_by: @invited_by,
        expires_at: @expires_in.from_now
      )
      DomainEvents.publish("user.invited", email: @email, role: @role, invitation_id: inv.id)
    end
    Result.ok(invitation: inv)
  rescue ActiveRecord::RecordInvalid => e
    Result.fail(:invalid, message: e.record.errors.full_messages.join(", "))
  end
end
