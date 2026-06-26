# Ativa RLS com política tenant_isolation em todo data plane (ADR-0019).
# `protocol_definitions` já era escopada por aplicação (ADR-0016); agora
# por banco também.
class EnableRlsOnDataPlane < ActiveRecord::Migration[8.1]
  TABLES = %i[
    triagens
    conversations
    inbound_messages
    outbound_messages
    consents
    report_snapshots
    dashboard_metrics
    domain_events
    protocol_definitions
  ].freeze

  def up
    # RLS operations require table ownership. Use PG connection directly as rota_admin
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
      TABLES.each do |t|
        pg_conn.exec("ALTER TABLE #{t} OWNER TO rota_admin;")
        pg_conn.exec("ALTER TABLE #{t} ENABLE ROW LEVEL SECURITY;")
        pg_conn.exec("ALTER TABLE #{t} FORCE ROW LEVEL SECURITY;")
        pg_conn.exec(<<~SQL)
          CREATE POLICY tenant_isolation ON #{t}
            USING      (municipality_id = current_setting('app.municipality_id')::uuid)
            WITH CHECK (municipality_id = current_setting('app.municipality_id')::uuid)
        SQL
      end
    ensure
      pg_conn.close
    end
  end

  def down
    # Cleanup RLS
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
      TABLES.each do |t|
        pg_conn.exec("DROP POLICY IF EXISTS tenant_isolation ON #{t};")
        pg_conn.exec("ALTER TABLE #{t} NO FORCE ROW LEVEL SECURITY;")
        pg_conn.exec("ALTER TABLE #{t} DISABLE ROW LEVEL SECURITY;")
      end
    ensure
      pg_conn.close
    end
  end
end
