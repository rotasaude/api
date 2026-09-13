# Aceite de convite — PÚBLICO, o token é a credencial. Roda na cidade do host
# (CityResolution): convite, usuário, identidade e membership moram no banco da
# cidade, e membership.granted vai para o domain_events DELA (Ruling R18),
# nunca para a plataforma.
class AcceptInvitation
  def self.call(token:, password:)
    new(token: token, password: password).call
  end

  def initialize(token:, password:)
    @token, @password = token, password
  end

  def call
    inv = Invitation.find_by(token: @token)
    return Result.fail(:invalid_token) if inv.nil? || inv.expired? || inv.accepted_at.present?

    user = nil
    ApplicationRecord.transaction do
      user = User.create!(email_address: inv.email, password: @password)
      Identity.create!(user: user, provider: "password", provider_uid: inv.email)
      Membership.create!(
        user: user,
        role: inv.role,
        granted_by: inv.invited_by,
        granted_at: Time.current
      )
      inv.update!(accepted_at: Time.current)
      DomainEvents.publish("membership.granted", user_id: user.id, role: inv.role)
    end

    Result.ok(user: user)
  end
end
