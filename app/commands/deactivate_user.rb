# Desativa um usuário da cidade da conexão corrente. user.deactivated vai para o
# domain_events da cidade (Ruling R18), nunca para a plataforma.
class DeactivateUser
  def self.call(user_id:, by:)
    user = User.find(user_id)
    ApplicationRecord.transaction do
      user.deactivate!
      DomainEvents.publish("user.deactivated", user_id: user.id, by: by.id)
    end
    Result.ok(user: user)
  end
end
