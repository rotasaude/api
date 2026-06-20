class DeactivateUser
  def self.call(user_id:, by:)
    ApplicationRecord.connected_to(role: :admin) do
      user = User.find(user_id)
      user.deactivate!
      Platform.audit("user.deactivated", user_id: user.id, by: by.id)
      Result.ok(user: user)
    end
  end
end
