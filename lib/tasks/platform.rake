# Bootstrap do banco de PLATAFORMA. Roda como superuser porque criar database
# e role exige privilégio que rota_app não tem — e não deve ter.
require "open3"
require "pg"

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

  desc "Instala os triggers do banco de plataforma (idempotente)."
  # Existe porque db/platform_schema.rb não representa trigger, e banco vazio
  # nasce do schema, não das migrações: `db:migrate` num banco sem tabelas
  # carrega o dump e marca TODAS as versões como aplicadas, sem executar
  # nenhuma. Foi assim que a CI rodou a suíte pela primeira vez com a
  # imutabilidade da auditoria de manutenção ausente — e seria assim numa
  # plataforma recém-provisionada. Mesmo desenho do city:load_schema, que já
  # executa db/city_triggers.sql depois de carregar o schema da cidade.
  #
  # Roda pela conexão de plataforma (dona das tabelas): criar trigger em
  # platform_events exige ser dono da tabela.
  task triggers: :environment do
    file = Rails.root.join("db/platform_triggers.sql")
    abort "[platform:triggers] #{file} não existe." unless File.exist?(file)

    PlatformRecord.connection.execute(File.read(file))
    puts "[platform:triggers] instalados em #{PlatformRecord.connection.current_database}"
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
    # a URL a partir de ROTA_PROVISIONER_PASSWORD). A senha vai cifrada (SCRAM) via
    # PG#encrypt_password, nunca em texto no SQL nem no argv de um subprocesso.
    provisioner_pwd = ENV.fetch("ROTA_PROVISIONER_PASSWORD", "rota_provisioner")
    begin
      conn = PG.connect(host: p[:host], port: p[:port], dbname: "postgres", user: p[:su_user], password: p[:su_pwd])
      conn.set_notice_receiver { |_| }
      secret = conn.escape_literal(conn.encrypt_password(provisioner_pwd, "rota_provisioner", "scram-sha-256"))
      role_exists = conn.exec_params("SELECT 1 FROM pg_roles WHERE rolname = $1", [ "rota_provisioner" ]).ntuples == 1
      # M4 (hardening review, Task 3): INHERIT explicit, not just the Postgres
      # default — a pre-existing NOINHERIT rota_provisioner (e.g. hand-edited,
      # or created by a future script that doesn't default to INHERIT) would
      # silently break CityDatabase.drop!'s ALTER/DROP DATABASE steps, which
      # rely on rota_provisioner having the privileges of the city role it is
      # GRANTed into (ensure!) without an explicit SET ROLE.
      if role_exists
        conn.exec("ALTER ROLE rota_provisioner LOGIN CREATEDB CREATEROLE NOSUPERUSER INHERIT PASSWORD #{secret}")
      else
        conn.exec("CREATE ROLE rota_provisioner LOGIN CREATEDB CREATEROLE INHERIT PASSWORD #{secret}")
      end
    rescue PG::Error => e
      abort "[platform:bootstrap] falha no role rota_provisioner: #{e.class}"
    ensure
      conn&.close
    end

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
