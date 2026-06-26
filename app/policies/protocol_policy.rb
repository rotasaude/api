class ProtocolPolicy < ApplicationPolicy
  def author?
    role?(:protocol_author, @record.municipality_id)
  end

  def publish?
    role?(:protocol_publisher, @record.municipality_id)
  end

  # Vigência por cidade (ADR-0009). Nível de permissão "decidido na aplicação":
  # publisher OU municipal_admin da cidade pode ativar uma versão published.
  def activate?
    role?(:protocol_publisher, @record.municipality_id) ||
      role?(:municipal_admin, @record.municipality_id)
  end

  def view?
    role?(:viewer, @record.municipality_id) || author? || publish?
  end
end
