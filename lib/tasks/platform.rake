# Bootstrap do banco de PLATAFORMA. Roda como superuser porque criar database
# e role exige privilégio que rota_app não tem — e não deve ter.
require "open3"

namespace :platform do
  def platform_conn_params
    cfg = ActiveRecord::Base.configurations
                            .configs_for(env_name: Rails.env, name: "platform")
                            .configuration_hash
    {
      db:      cfg[:database],
      host:    ENV.fetch("DATABASE_HOST", cfg[:host] || "127.0.0.1").to_s,
      port:    ENV.fetch("DATABASE_PORT", cfg[:port] || 5432).to_s,
      su_user: ENV.fetch("BOOTSTRAP_SUPERUSER", "rota_saude"),
      su_pwd:  ENV.fetch("POSTGRES_PASSWORD") { abort "[platform:bootstrap] POSTGRES_PASSWORD ausente." }
    }
  end

  desc "Cria o database e o role da plataforma (idempotente)."
  task bootstrap: :environment do
    p   = platform_conn_params
    pwd = ENV.fetch("ROTA_PLATFORM_PASSWORD", "rota_platform")
    env = { "PGPASSWORD" => p[:su_pwd] }
    base = ["psql", "-h", p[:host], "-p", p[:port], "-U", p[:su_user], "-v", "ON_ERROR_STOP=1"]

    role_sql = <<~SQL
      DO $$ BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='rota_platform') THEN
          CREATE ROLE rota_platform LOGIN PASSWORD '#{pwd}';
        END IF;
      END $$;
    SQL
    out, st = Open3.capture2e(env, *base, "-d", "postgres", "-c", role_sql)
    abort "[platform:bootstrap] falha no role:\n#{out}" unless st.success?

    # Papel que cria e apaga banco e role de cada cidade (Plano 4): CREATEDB e
    # CREATEROLE, sem superusuário. Existe uma vez no cluster; o provisionamento
    # conecta com ele por PROVISIONER_DATABASE_URL (em dev/test, CityDatabase monta
    # a URL a partir de ROTA_PROVISIONER_PASSWORD).
    provisioner_pwd = ENV.fetch("ROTA_PROVISIONER_PASSWORD", "rota_provisioner")
    provisioner_sql = <<~SQL
      DO $$ BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='rota_provisioner') THEN
          CREATE ROLE rota_provisioner LOGIN CREATEDB CREATEROLE PASSWORD '#{provisioner_pwd}';
        ELSE
          ALTER ROLE rota_provisioner LOGIN CREATEDB CREATEROLE NOSUPERUSER;
        END IF;
      END $$;
    SQL
    out, st = Open3.capture2e(env, *base, "-d", "postgres", "-c", provisioner_sql)
    abort "[platform:bootstrap] falha no role rota_provisioner:\n#{out}" unless st.success?

    exists, = Open3.capture2e(env, *base, "-tA", "-d", "postgres",
                              "-c", "SELECT 1 FROM pg_database WHERE datname='#{p[:db]}'")
    if exists.strip == "1"
      puts "[platform:bootstrap] #{p[:db]} já existe"
    else
      out, st = Open3.capture2e(env, *base, "-d", "postgres",
                                "-c", "CREATE DATABASE #{p[:db]} OWNER rota_platform")
      abort "[platform:bootstrap] falha ao criar #{p[:db]}:\n#{out}" unless st.success?
      puts "[platform:bootstrap] #{p[:db]} criado"
    end
  end
end
