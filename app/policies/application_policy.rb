class ApplicationPolicy
  def initialize(user, record)
    @user, @record = user, record
  end

  private

  def role?(role, municipality_id)
    return false if @user.nil?
    @user.operator? || @user.role_in?(municipality_id, role: role.to_s)
  end
end
