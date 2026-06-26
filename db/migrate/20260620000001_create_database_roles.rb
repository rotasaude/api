# Cria os dois papéis exigidos pelo ADR-0019.
#   rota_app  : sujeito a RLS (FORCE)
#   rota_admin: BYPASSRLS, usado por recurring tasks e migrations
class CreateDatabaseRoles < ActiveRecord::Migration[8.1]
  def up
    app_pwd   = ENV.fetch("ROTA_APP_PASSWORD", "rota_app")
    admin_pwd = ENV.fetch("ROTA_ADMIN_PASSWORD", "rota_admin")

    execute(<<~SQL.squish)
      DO $$
      BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rota_app') THEN
          CREATE ROLE rota_app LOGIN PASSWORD '#{app_pwd}';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rota_admin') THEN
          CREATE ROLE rota_admin LOGIN PASSWORD '#{admin_pwd}' BYPASSRLS;
        END IF;
      END $$;
    SQL

    # Privilégios. As tabelas existem; novas criadas depois herdam por default privileges.
    execute("GRANT CONNECT ON DATABASE #{connection.current_database} TO rota_app, rota_admin;")
    execute("GRANT USAGE ON SCHEMA public TO rota_app, rota_admin;")
    execute("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO rota_app, rota_admin;")
    execute("GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO rota_app, rota_admin;")
    execute("ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO rota_app, rota_admin;")
    execute("ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO rota_app, rota_admin;")
  end

  def down
    execute("REVOKE ALL ON ALL TABLES IN SCHEMA public FROM rota_app, rota_admin;")
    execute("REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM rota_app, rota_admin;")
    execute("REVOKE ALL ON SCHEMA public FROM rota_app, rota_admin;")
    execute("REVOKE ALL ON DATABASE #{connection.current_database} FROM rota_app, rota_admin;")
    execute("DROP ROLE IF EXISTS rota_app;")
    execute("DROP ROLE IF EXISTS rota_admin;")
  end
end
