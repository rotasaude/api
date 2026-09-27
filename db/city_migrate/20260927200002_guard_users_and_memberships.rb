# Usuário e membership nunca apagados; membership só recebe a revogação, uma
# vez (ADR-0012; fechamento do módulo 06). Só trigger, sem mudança de tabela:
# vem de db/city_triggers.sql, como GuardConsentTerms e GuardProtocolDefinitions.
class GuardUsersAndMemberships < ActiveRecord::Migration[8.1]
  def up
    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    execute "DROP TRIGGER IF EXISTS memberships_guard ON memberships"
    execute "DROP TRIGGER IF EXISTS users_no_delete ON users"
    execute "DROP FUNCTION IF EXISTS rota_membership_guard()"
  end
end
