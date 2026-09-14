class ApplicationPolicy
  def initialize(user, record)
    @user, @record = user, record
  end

  private

  # Papel do usuário na cidade da conexão corrente — o banco é da cidade, então
  # não há município a comparar.
  def role?(role)
    return false if @user.nil?
    @user.has_role?(role)
  end
end
