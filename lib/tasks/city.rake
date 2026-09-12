require "open3"

namespace :city do
  TEST_CITY_DATABASES = %w[rota_saude_test_city_a rota_saude_test_city_b].freeze

  desc "Cria os bancos de cidade usados pelos specs de isolamento (idempotente)."
  task test_databases: :environment do
    su   = ENV.fetch("BOOTSTRAP_SUPERUSER", "rota_saude")
    pwd  = ENV.fetch("POSTGRES_PASSWORD") { abort "[city:test_databases] POSTGRES_PASSWORD ausente." }
    host = ENV.fetch("DATABASE_HOST", "127.0.0.1")
    port = ENV.fetch("DATABASE_PORT", "5432").to_s
    env  = { "PGPASSWORD" => pwd }
    base = ["psql", "-h", host, "-p", port, "-U", su, "-v", "ON_ERROR_STOP=1"]

    TEST_CITY_DATABASES.each do |db|
      exists, = Open3.capture2e(env, *base, "-tA", "-d", "postgres",
                                "-c", "SELECT 1 FROM pg_database WHERE datname='#{db}'")
      if exists.strip == "1"
        puts "[city:test_databases] #{db} já existe"
        next
      end
      out, st = Open3.capture2e(env, *base, "-d", "postgres", "-c", "CREATE DATABASE #{db} OWNER #{su}")
      abort "[city:test_databases] falha ao criar #{db}:\n#{out}" unless st.success?
      puts "[city:test_databases] #{db} criado"
    end

    TEST_CITY_DATABASES.each do |db|
      out, st = Open3.capture2e(env, *base, "-d", db, "-c",
        "CREATE TABLE IF NOT EXISTS probes (id serial PRIMARY KEY, label text NOT NULL)")
      abort "[city:test_databases] falha ao criar probes em #{db}:\n#{out}" unless st.success?
    end
  end

  desc "Registra uma cidade no catálogo (dev). Uso: city:create[slug,nome,uf]"
  task :create, %i[slug name uf] => :environment do |_t, args|
    abort "uso: rails 'city:create[slug,nome,uf]'" if args[:slug].blank? || args[:name].blank?
    city = CityProvisioner.call(slug: args[:slug], name: args[:name], uf: args[:uf])
    puts "[city:create] #{city.slug} → #{city.status} (#{city.database_url.sub(/:[^:@]+@/, ':***@')})"
  end
end
