# Helper para ativar Row-Level Security com a política tenant_isolation
# padrão (ver ADR-0019). Garante `FORCE ROW LEVEL SECURITY` (sem ele o dono
# da tabela ignora RLS).
module MigrationHelpers
  module Rls
    def enable_rls_on(table_name, column: :municipality_id)
      execute("ALTER TABLE #{table_name} ENABLE ROW LEVEL SECURITY;")
      execute("ALTER TABLE #{table_name} FORCE ROW LEVEL SECURITY;")
      execute(<<~SQL.squish)
        CREATE POLICY tenant_isolation ON #{table_name}
          USING      (#{column} = current_setting('app.municipality_id')::bigint)
          WITH CHECK (#{column} = current_setting('app.municipality_id')::bigint);
      SQL
    end

    def disable_rls_on(table_name)
      execute("DROP POLICY IF EXISTS tenant_isolation ON #{table_name};")
      execute("ALTER TABLE #{table_name} NO FORCE ROW LEVEL SECURITY;")
      execute("ALTER TABLE #{table_name} DISABLE ROW LEVEL SECURITY;")
    end
  end
end

ActiveRecord::Migration.include(MigrationHelpers::Rls)
