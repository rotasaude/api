require "open3"

namespace :city do
  # Local variable, not a constant: a `namespace` block does not scope
  # constants either — `TEST_CITY_DATABASES = ...` here would assign at the
  # top level, same class of collision as SELF_PATH in the architecture spec.
  # A local var is captured by the task blocks' closures without leaking.
  test_city_databases = %w[rota_saude_test_city_a rota_saude_test_city_b].freeze

  # Destino do shard `bootstrap` de CityRecord (ver config/database.yml e
  # app/models/city_record.rb). Precisa EXISTIR — RSpec's
  # setup_transactional_fixtures pina/verifica todo pool registrado antes de
  # cada exemplo, inclusive o shard bootstrap, então um banco ausente derruba
  # a suíte inteira, não só quem usa CityRecord. Mas fica sem NENHUMA tabela
  # de propósito: sem cidade selecionada, qualquer query de domínio nesse
  # shard levanta ActiveRecord::StatementInvalid (PG::UndefinedTable) em vez
  # de servir dado real — nunca crie tabelas nem carregue schema aqui.
  no_city_selected_database = "rota_saude_no_city_selected"

  desc "Cria os bancos de cidade usados pelos specs de isolamento (idempotente)."
  task test_databases: :environment do
    su   = ENV.fetch("BOOTSTRAP_SUPERUSER", "rota_saude")
    pwd  = ENV.fetch("POSTGRES_PASSWORD") { abort "[city:test_databases] POSTGRES_PASSWORD ausente." }
    host = ENV.fetch("DATABASE_HOST", "127.0.0.1")
    port = ENV.fetch("DATABASE_PORT", "5432").to_s
    env  = { "PGPASSWORD" => pwd }
    base = ["psql", "-h", host, "-p", port, "-U", su, "-v", "ON_ERROR_STOP=1"]

    (test_city_databases + [no_city_selected_database]).each do |db|
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

    test_city_databases.each do |db|
      out, st = Open3.capture2e(env, *base, "-d", db, "-c",
        "CREATE TABLE IF NOT EXISTS probes (id serial PRIMARY KEY, label text NOT NULL)")
      abort "[city:test_databases] falha ao criar probes em #{db}:\n#{out}" unless st.success?
    end
    # #{no_city_selected_database} fica de propósito sem nenhuma tabela — ver
    # comentário acima.
  end

  desc "Registra uma cidade no catálogo (dev). Uso: city:create[slug,nome,uf]"
  task :create, %i[slug name uf] => :environment do |_t, args|
    # Provisionamento real (papel rota_provisioner, least-privilege — ADR-0003)
    # é o Plano 4. Até lá, database_url_for mina URLs com credencial de
    # superusuário de bootstrap: rodar isso fora de development daria a
    # qualquer pool de cidade acesso de leitura a todas as outras.
    abort "[city:create] só roda em development; provisionamento real é um plano futuro." unless Rails.env.development?
    abort "uso: rails 'city:create[slug,nome,uf]'" if args[:slug].blank? || args[:name].blank?
    result = CityProvisioner.call(slug: args[:slug], name: args[:name], uf: args[:uf])
    abort "[city:create] falhou: #{result.message}" if result.failure?

    city = result.payload[:city]
    puts "[city:create] #{city.slug} → #{city.status} (#{city.database_url.sub(/:[^:@]+@/, ':***@')})"
  end
end
