# Validação presencial (spec 2026-09-24 §2): quem valida e quem desfaz.
class CitizenVerificationPolicy < ApplicationPolicy
  def verify?
    role?(:citizen_verifier)
  end

  def manage?
    role?(:municipal_admin)
  end
end
