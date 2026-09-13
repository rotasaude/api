class MembershipPolicy < ApplicationPolicy
  # @record = { target_user: }
  def manage?
    role?(:municipal_admin)
  end

  def list?
    manage?
  end
end
