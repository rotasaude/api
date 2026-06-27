# Bootstrap-from-zero do banco sob ADR-0019. db:migrate num banco novo carrega o
# schema.rb (Ruby), que NÃO representa RLS/ownership (SQL cru). Aqui carregamos um
# db/structure.sql (pg_dump --schema-only) como superuser rota_saude, reproduzindo
# RLS + ownership + least-priv fielmente.
# Ver docs/superpowers/specs/2026-06-26-db-bootstrap-from-zero-design.md
require "open3"

namespace :db do
  STRUCTURE_SQL = File.expand_path("../../db/structure.sql", __dir__)

  def bootstrap_conn_params
    cfg = ActiveRecord::Base.connection_db_config.configuration_hash
    {
      db:      ENV.fetch("BOOTSTRAP_DATABASE", cfg[:database]),
      host:    ENV.fetch("DATABASE_HOST", cfg[:host] || "127.0.0.1").to_s,
      port:    ENV.fetch("DATABASE_PORT", cfg[:port] || 5432).to_s,
      su_user: ENV.fetch("BOOTSTRAP_SUPERUSER", "rota_saude"),
      su_pwd:  ENV.fetch("POSTGRES_PASSWORD") { abort "[db:bootstrap] POSTGRES_PASSWORD ausente — o passo privilegiado exige o superuser." }
    }
  end

  desc "Provisiona roles e carrega db/structure.sql (RLS) como superuser. Idempotente."
  task bootstrap: :environment do
    p = bootstrap_conn_params
    abort "[db:bootstrap] #{STRUCTURE_SQL} não existe — rode `rails db:bootstrap:dump`." unless File.exist?(STRUCTURE_SQL)

    app_pwd   = ENV.fetch("ROTA_APP_PASSWORD", "rota_app")
    admin_pwd = ENV.fetch("ROTA_ADMIN_PASSWORD", "rota_admin")
    env       = { "PGPASSWORD" => p[:su_pwd] }
    base      = ["psql", "-h", p[:host], "-p", p[:port], "-U", p[:su_user], "-v", "ON_ERROR_STOP=1"]

    puts "[db:bootstrap] (1/2) papéis + memberships em #{p[:db]} como #{p[:su_user]}"
    roles_sql = <<~SQL
      DO $$ BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='rota_app')   THEN CREATE ROLE rota_app   LOGIN PASSWORD '#{app_pwd}'; END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='rota_admin') THEN CREATE ROLE rota_admin LOGIN PASSWORD '#{admin_pwd}' BYPASSRLS; END IF;
      END $$;
      GRANT rota_saude TO rota_admin;
    SQL
    out, st = Open3.capture2e(env, *base, "-d", p[:db], "-c", roles_sql)
    abort "[db:bootstrap] falha nos papéis:\n#{out}" unless st.success?

    puts "[db:bootstrap] (2/2) carregando structure.sql em #{p[:db]}"
    out, st = Open3.capture2e(env, *base, "-d", p[:db], "-f", STRUCTURE_SQL)
    abort "[db:bootstrap] falha no load do structure.sql:\n#{out}" unless st.success?

    puts "[db:bootstrap] OK — #{p[:db]} provisionado do zero (com RLS)."
  end

  namespace :bootstrap do
    desc "Regenera db/structure.sql via pg_dump --schema-only do banco corrente."
    task dump: :environment do
      p   = bootstrap_conn_params
      env = { "PGPASSWORD" => p[:su_pwd] }
      out, st = Open3.capture2(env, "pg_dump", "-h", p[:host], "-p", p[:port],
                               "-U", p[:su_user], "--schema-only", p[:db])
      abort "[db:bootstrap:dump] pg_dump falhou:\n#{out}" unless st.success?
      File.write(STRUCTURE_SQL, out)
      puts "[db:bootstrap:dump] OK — #{STRUCTURE_SQL} (#{out.lines.size} linhas)."
    end
  end
end
