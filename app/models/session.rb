# Sessão da cidade (ADR-0011), no banco da cidade. Exatamente um ator:
#   - usuário da cidade (login por senha ou gov.br), ou
#   - operador da plataforma que entrou por grant assinado (Plano 3B) — sem
#     conta na cidade; operator_id é o id da conta de plataforma.
# Sessão de operador é SÓ LEITURA (Authentication nega por padrão), vale
# OPERATOR_GRANT_TTL e cai quando o operador é desativado na plataforma.
class Session < ApplicationRecord
  OPERATOR_GRANT_TTL = 1.hour

  belongs_to :user, optional: true

  validate :exactly_one_actor

  def operator_grant?
    operator_id.present?
  end

  def operator
    return nil unless operator_grant?

    @operator ||= Operator.find_by(id: operator_id)
  end

  def usable?
    return true unless operator_grant?

    created_at > OPERATOR_GRANT_TTL.ago && operator&.active? == true
  end

  private

  def exactly_one_actor
    return if user_id.present? ^ operator_id.present?

    errors.add(:base, "a session belongs to exactly one of a user or an operator")
  end
end
