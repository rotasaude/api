# Concede um papel a um usuário que já existe na cidade da conexão corrente
# (spec de assinaturas §3). Até aqui um papel só nascia pelo convite; o
# revisor de protocolo é, em geral, alguém que já é publisher.
#
# Duas recusas, nesta ordem:
#   1. um papel de Membership::PRIVILEGED_ROLES só é concedido por um ator cujo
#      actor_kind é "user" — ALLOWLIST, não denylist "!= maintainer": checar o
#      tipo permitido, em vez de enumerar os proibidos, não depende de listar
#      todo tipo de ator que já existe ou vier a existir (M8, rodada de
#      revisão). O mantenedor é recusado assim, sem checar papel nenhum — ele
#      responde "sim" a toda pergunta de papel;
#   2. quem concede precisa ser municipal_admin (MembershipPolicy#manage?).
#
# Append-only como o resto de memberships: conceder cria uma linha; revogar é
# RevokeMembership (fim de vigência).
class GrantRole
  def self.call(user_id:, role:, by:)
    return Result.fail(:city_missing) if Current.city.nil?
    return Result.fail(:invalid_role) unless Membership::ROLES.include?(role.to_s)

    if Membership::PRIVILEGED_ROLES.include?(role.to_s)
      authorized_actor = by.respond_to?(:actor_kind) && by.actor_kind == "user"
      unless authorized_actor
        return Result.fail(:forbidden_for_maintainer,
                           message: "o mantenedor não concede #{role}: quem aprova protocolo é escolhido pela cidade")
      end
    end
    return Result.fail(:forbidden) unless MembershipPolicy.new(by, nil).manage?

    user = User.find_by(id: user_id)
    return Result.fail(:user_not_found) if user.nil?
    return Result.fail(:user_inactive) unless user.active?
    return Result.fail(:already_granted) if user.has_role?(role)

    membership = nil
    ApplicationRecord.transaction do
      membership = Membership.create!(user: user, role: role.to_s, granted_at: Time.current,
                                      granted_by_id: (by.id if by.actor_kind == "user"))
      DomainEvents.publish("membership.granted", user_id: user.id, role: role.to_s,
                                                 by: by.id, actor_kind: by.actor_kind)
    end

    Result.ok(membership: membership)
  rescue ActiveRecord::RecordInvalid => e
    Result.fail(:invalid, message: e.record.errors.full_messages.join(", "))
  end
end
