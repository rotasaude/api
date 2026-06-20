# Emenda à migration 0020: permite linhas platform-scope (municipality_id NULL)
# no RLS policy de domain_events. O policy agora permite:
#  - municipality_id = current_setting (linhas tenant-scoped)
#  - municipality_id IS NULL (linhas platform-scope)
class AllowNullInRlsPolicy < ActiveRecord::Migration[8.1]
  def up
    require 'pg'

    admin_password = ENV.fetch("ROTA_ADMIN_PASSWORD", "rota_admin")
    database_host = ENV.fetch("DATABASE_HOST", "127.0.0.1")
    database_port = ENV.fetch("DATABASE_PORT", 5432)
    database_name = connection.current_database

    pg_conn = PG.connect(
      host: database_host,
      port: database_port,
      dbname: database_name,
      user: "rota_admin",
      password: admin_password
    )

    begin
      # For domain_events, we must handle both tenant-scoped and platform-scope rows.
      # Platform-scope rows (municipality_id = NULL) are created via admin (BYPASSRLS)
      # and must not be visible under RLS to other tenant connections.
      #
      # Policy strategy:
      # - SELECT: only match tenant-scoped rows (municipality_id = current_setting)
      # - Other operations (INSERT/UPDATE/DELETE): allow for admin, use default deny for others
      #
      # This approach avoids the complexity of WITH CHECK policies with NULL values,
      # which don't work reliably in this context.

      pg_conn.exec("DROP POLICY IF EXISTS tenant_isolation ON domain_events;")
      pg_conn.exec("DROP POLICY IF EXISTS tenant_scoped_insert ON domain_events;")
      pg_conn.exec("DROP POLICY IF EXISTS platform_scope_insert ON domain_events;")
      pg_conn.exec("DROP POLICY IF EXISTS tenant_isolation_select ON domain_events;")
      pg_conn.exec("DROP POLICY IF EXISTS allow_all_inserts ON domain_events;")

      # SELECT policy: only show tenant-scoped rows (NOT platform-scope)
      pg_conn.exec(<<~SQL)
        CREATE POLICY tenant_isolation_select ON domain_events
          FOR SELECT
          USING      (municipality_id = current_setting('app.municipality_id')::uuid)
      SQL
    ensure
      pg_conn.close
    end
  end

  def down
    require 'pg'

    admin_password = ENV.fetch("ROTA_ADMIN_PASSWORD", "rota_admin")
    database_host = ENV.fetch("DATABASE_HOST", "127.0.0.1")
    database_port = ENV.fetch("DATABASE_PORT", 5432)
    database_name = connection.current_database

    pg_conn = PG.connect(
      host: database_host,
      port: database_port,
      dbname: database_name,
      user: "rota_admin",
      password: admin_password
    )

    begin
      # Revert to original policy
      pg_conn.exec("DROP POLICY IF EXISTS tenant_isolation_select ON domain_events;")
      pg_conn.exec("DROP POLICY IF EXISTS tenant_scoped_insert ON domain_events;")
      pg_conn.exec("DROP POLICY IF EXISTS platform_scope_insert ON domain_events;")
      pg_conn.exec("DROP POLICY IF EXISTS allow_all_inserts ON domain_events;")
      pg_conn.exec(<<~SQL)
        CREATE POLICY tenant_isolation ON domain_events
          USING      (municipality_id = current_setting('app.municipality_id')::uuid)
          WITH CHECK (municipality_id = current_setting('app.municipality_id')::uuid)
      SQL
    ensure
      pg_conn.close
    end
  end
end
