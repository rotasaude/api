# Revoga um membership na cidade da conexão corrente. membership.revoked vai para
# o domain_events da cidade (Ruling R18), nunca para a plataforma.
class RevokeMembership
  def self.call(membership_id:, by:)
    m = Membership.find(membership_id)
    return Result.fail(:already_revoked, message: "este papel já foi revogado") if m.revoked_at.present?

    ApplicationRecord.transaction do
      m.update!(revoked_at: Time.current)
      DomainEvents.publish("membership.revoked", user_id: m.user_id, role: m.role, by: by.id)
    end

    Result.ok(membership: m)
  end
end
