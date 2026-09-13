class ProtocolPolicy < ApplicationPolicy
  def author?
    role?(:protocol_author)
  end

  def publish?
    role?(:protocol_publisher)
  end

  # Vigência por cidade (ADR-0009). Nível de permissão "decidido na aplicação":
  # publisher OU municipal_admin da cidade pode ativar uma versão published.
  def activate?
    role?(:protocol_publisher) ||
      role?(:municipal_admin)
  end

  def view?
    role?(:viewer) || author? || publish?
  end
end
