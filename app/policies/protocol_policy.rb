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

  # Quem assina uma versão (spec de assinaturas S1). Papel próprio, separado de
  # quem publica. NOTA: o mantenedor responde "sim" a esta pergunta (D6) — é
  # Protocols::Sign que o recusa, pelo tipo de ator.
  def review?
    role?(:protocol_reviewer)
  end
end
