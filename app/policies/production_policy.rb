# Produção e-SUS (spec §6.5; contratos §5.3): municipal_admin e analyst leem;
# só o municipal_admin reenvia.
class ProductionPolicy < ApplicationPolicy
  def read?
    role?(:municipal_admin) || role?(:analyst)
  end

  def resend?
    role?(:municipal_admin)
  end
end
