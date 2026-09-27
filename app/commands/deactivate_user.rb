# Desativa um usuário da cidade da conexão corrente. user.deactivated vai para o
# domain_events da cidade (Ruling R18), nunca para a plataforma.
#
# Desativar também revoga os papéis ativos (fechamento do módulo 06), cada um
# pelo caminho de sempre — RevokeMembership, que publica membership.revoked —
# e tudo na mesma transação: ou o usuário sai inteiro, ou nada muda.
class DeactivateUser
  class RevokeFailed < StandardError; end

  def self.call(user_id:, by:)
    user = User.find(user_id)
    return Result.fail(:cannot_deactivate_self, message: "você não pode desativar a própria conta") if user.id == by.id
    return Result.fail(:already_deactivated, message: "este usuário já está desativado") unless user.active?

    ApplicationRecord.transaction do
      user.memberships.active.find_each do |membership|
        revoked = RevokeMembership.call(membership_id: membership.id, by: by)
        raise RevokeFailed, "membership #{membership.id}: #{revoked.reason}" if revoked.failure?
      end
      user.deactivate!
      DomainEvents.publish("user.deactivated", user_id: user.id, by: by.id)
    end
    Result.ok(user: user)
  end
end
