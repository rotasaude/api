# identities foi criada por rota_admin em 20260620000040, sem GRANT explícito.
# ALTER DEFAULT PRIVILEGES do 20260620000001 não cobre tabelas criadas por rota_admin.
# Fix: grant explícito (mesmo padrão de 20260620000070 e 20260620000080).
class GrantIdentitiesToAppRoles < ActiveRecord::Migration[8.1]
  def up
    execute("GRANT SELECT, INSERT, UPDATE, DELETE ON identities TO rota_app, rota_saude;")
  end

  def down
    execute("REVOKE SELECT, INSERT, UPDATE, DELETE ON identities FROM rota_app, rota_saude;")
  end
end
