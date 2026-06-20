class AcceptInvitation
  def self.call(token:, password:)
    new(token: token, password: password).call
  end

  def initialize(token:, password:)
    @token, @password = token, password
  end

  def call
    inv = nil
    user = nil

    ApplicationRecord.connected_to(role: :admin) do
      inv = Invitation.find_by(token: @token)
      return Result.fail(:invalid_token) if inv.nil? || inv.expired? || inv.accepted_at.present?

      ApplicationRecord.transaction do
        user = User.create!(email_address: inv.email, password: @password)
        Identity.create!(user: user, provider: "password", provider_uid: inv.email)
        Membership.create!(
          user: user,
          municipality_id: inv.municipality_id,
          role: inv.role,
          granted_by: inv.invited_by,
          granted_at: Time.current
        )
        inv.update!(accepted_at: Time.current)
      end
    end

    if inv.municipality_id
      Current.municipality_id = inv.municipality_id
      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute(
          ApplicationRecord.sanitize_sql(["SET LOCAL app.municipality_id = ?", inv.municipality_id])
        )
        DomainEvents.publish("membership.granted", user_id: user.id, role: inv.role)
      end
    else
      Platform.audit("membership.granted", user_id: user.id, role: inv.role)
    end

    Result.ok(user: user)
  end
end
