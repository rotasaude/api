class MembershipPolicy < ApplicationPolicy
  # @record = { target_user:, municipality_id: }
  def manage?
    role?(:municipal_admin, @record[:municipality_id])
  end

  def list?
    manage?
  end
end
