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

  # PRECONDIÇÃO: a DB-alvo deve estar VAZIA. O load do structure.sql usa CREATE TABLE
  # sem IF NOT EXISTS — re-rodar contra uma DB já populada falha. Os callers garantem
  # banco vazio: start.sh --reset faz createdb fresco; bin/verify-bootstrap dropa+recria
  # o scratch. (Os passos de roles e de carimbo de schema_migrations são idempotentes;
  # o load do schema NÃO é.)
  desc "Cria roles e carrega db/structure.sql (RLS) como superuser numa DB VAZIA."
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

    # (3/3) Carimba schema_migrations para que db:migrate do entrypoint seja no-op.
    # structure.sql é --schema-only; schema_migrations fica vazia após o load.
    # Sem esse passo, db:migrate tentaria re-rodar todas as migrations como rota_app,
    # que não tem CREATE no schema public (least-priv ADR-0019) e falharia.
    puts "[db:bootstrap] (3/3) carimbando schema_migrations em #{p[:db]}"
    migration_dir = File.expand_path("../../db/migrate", __dir__)
    versions = Dir.glob("#{migration_dir}/[0-9]*.rb")
                  .map { |f| File.basename(f).split("_").first }
                  .sort
    if versions.any?
      unless versions.all? { |v| v.match?(/\A\d+\z/) }
        abort "[db:bootstrap] versões de migration não-numéricas: #{versions.reject { |v| v.match?(/\A\d+\z/) }.inspect}"
      end
      values = versions.map { |v| "('#{v}')" }.join(", ")
      stamp_sql = "INSERT INTO schema_migrations (version) VALUES #{values} ON CONFLICT DO NOTHING;"
      out, st = Open3.capture2e(env, *base, "-d", p[:db], "-c", stamp_sql)
      abort "[db:bootstrap] falha ao carimbar schema_migrations:\n#{out}" unless st.success?
    end

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
