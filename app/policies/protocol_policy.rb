class ProtocolPolicy < ApplicationPolicy
  def author?
    role?(:protocol_author, @record.municipality_id)
  end

  def publish?
    role?(:protocol_publisher, @record.municipality_id)
  end

  def view?
    role?(:viewer, @record.municipality_id) || author? || publish?
  end
end
