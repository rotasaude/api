class RevokeMembership
  def self.call(membership_id:, by:)
    ApplicationRecord.connected_to(role: :admin) do
      m = Membership.find(membership_id)
      return Result.fail(:already_revoked) if m.revoked_at.present?

      m.update!(revoked_at: Time.current)

      if m.municipality_id
        Current.municipality_id = m.municipality_id
        ApplicationRecord.transaction do
          ApplicationRecord.connection.execute(
            ApplicationRecord.sanitize_sql(["SET LOCAL app.municipality_id = ?", m.municipality_id])
          )
          DomainEvents.publish("membership.revoked", user_id: m.user_id, role: m.role, by: by.id)
        end
      else
        Platform.audit("membership.revoked", user_id: m.user_id, role: m.role, by: by.id)
      end

      Result.ok(membership: m)
    end
  end
end
