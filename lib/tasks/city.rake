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

  # Monta uma postgres:// URL local para um nome de banco, com as mesmas
  # credenciais de superuser de bootstrap usadas pelo resto deste arquivo.
  # Lambda (não método) de propósito — mesma razão de test_city_databases
  # ser variável local: um `def` dentro de `namespace` vaza para o escopo
  # top-level do processo Rake.
  city_database_url = lambda do |name|
    host = ENV.fetch("DATABASE_HOST", "127.0.0.1")
    port = ENV.fetch("DATABASE_PORT", "5432")
    user = ENV.fetch("BOOTSTRAP_SUPERUSER", "rota_saude")
    pwd  = ENV.fetch("POSTGRES_PASSWORD") { abort "[city] POSTGRES_PASSWORD ausente." }
    "postgres://#{user}:#{pwd}@#{host}:#{port}/#{name}"
  end

  # Nomes de config (config/database.yml) cujo banco NUNCA pode receber o
  # schema de cidade: primary é o banco vazio rota_saude_no_city_selected,
  # cache é o banco de plataforma (Solid Cache, Plano 5), platform é o
  # catálogo/roteamento entre cidades, e city_unset é o banco
  # deliberadamente-vazio que faz o shard `bootstrap` falhar fechado (ver
  # comentário de no_city_selected_database acima) — carregar QUALQUER coisa
  # nele destruiria essa garantia. Os configs `admin` e `queue` saíram de
  # database.yml (Plano 2 Task 5 e Plano 5, respectivamente); os nomes seguem
  # na lista só como defesa, caso uma config com esse nome reapareça.
  protected_role_names = %w[primary admin queue cache platform city_unset].freeze

  # Bancos protegidos em TODO ambiente declarado em database.yml (development,
  # test, production, ...) — não só o Rails.env corrente. `configurations`
  # devolve um DatabaseConfig por (ambiente, nome); filtramos pelo nome do
  # role e pegamos o `database` resolvido, ignorando entradas sem banco
  # resolvível (ex.: production sem PLATFORM_DATABASE_URL setada neste
  # container).
  # Bancos compartilhados aposentados no Plano 5: primary/queue/cache apontavam para
  # eles. Não estão mais em database.yml, mas continuam existindo em dev e test com
  # dados antigos, então city:load_schema segue recusando-os.
  retired_database_names = %w[rota_saude_development rota_saude_test rota_saude_production].freeze

  protected_database_names = lambda do
    (ActiveRecord::Base.configurations.configurations
      .select { |cfg| protected_role_names.include?(cfg.name) }
      .filter_map { |cfg| cfg.respond_to?(:database) ? cfg.database.presence : nil } + retired_database_names)
      .uniq
  end

  # Resolve um nome de banco OU uma postgres:// URL para o nome REAL do banco
  # a que a conexão de fato vai apontar, para comparar contra
  # protected_database_names — sem abrir conexão (resolve só faz parsing).
  #
  # Bug corrigido (Minor do code review): comparar a string crua de um nome
  # "bare" contra protected_database_names, em vez de resolvê-la pela MESMA
  # URL que load_city_schema realmente monta e conecta, deixava passar
  # qualquer nome que o parser de URL normalizasse para um banco protegido —
  # ex.: "rota_saude_test?sslmode=disable" (tudo depois de "?" vira query
  # string, não faz parte do nome), "rota%5Fsaude_test" (%5F é "_" decodado)
  # ou "rota_saude_test#x" (tudo depois de "#" é descartado como fragment).
  # As três resolvem para o banco real "rota_saude_test". Por isso SEMPRE
  # montamos a URL primeiro (igual load_city_schema faz) e resolvemos ela,
  # nunca a string de entrada crua.
  resolve_database_name = lambda do |database_name_or_url|
    raw = database_name_or_url.to_s
    url = raw.include?("://") ? raw : city_database_url.call(raw)
    ActiveRecord::Base.configurations.resolve(url).database.to_s
  end

  # Carrega db/city_schema.rb (o dump do schema limpo de cidade — Task 4) num
  # banco de destino, identificado por nome (resolvido com as credenciais de
  # bootstrap) ou por uma postgres:// URL completa.
  #
  # Usa o mesmo mecanismo que `db:schema:load` do Rails usa por baixo
  # (ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection +
  # .load_schema), só que com um db_config resolvido ad-hoc — NUNCA registrado
  # em config/database.yml. Isso é deliberado: primary/queue/cache apontam
  # para o banco compartilhado, e um role `city` ali correria o risco de
  # qualquer `db:migrate`/`db:prepare` genérico tentar alcançá-lo.
  # with_temporary_connection troca a conexão de ActiveRecord::Base só durante
  # o load e restaura a original (o banco compartilhado) no `ensure`, então
  # esta task nunca toca primary/queue/cache.
  #
  # GUARDA (I6 do code review): a dump usa force: :cascade — um alvo errado
  # dropa e recria tabelas de domínio de verdade. Por isso, antes de tocar
  # em qualquer conexão: só development/test, e nunca um alvo que resolva
  # para o banco de primary/queue/cache/platform/city_unset (ou de uma config
  # `admin`, se reaparecer — ver protected_role_names).
  load_city_schema = lambda do |database_name_or_url|
    unless Rails.env.development? || Rails.env.test?
      abort "[city] city:load_schema só roda em development/test (env atual: #{Rails.env})."
    end

    target_database = resolve_database_name.call(database_name_or_url)
    if protected_database_names.call.include?(target_database)
      abort "[city] recusado: #{target_database.inspect} é o banco de primary/queue/cache/platform/city_unset — " \
            "city:load_schema nunca escreve lá (a dump usa force: :cascade)."
    end

    schema_file = Rails.root.join("db/city_schema.rb").to_s
    abort "[city] #{schema_file} não existe." unless File.exist?(schema_file)

    url = database_name_or_url.to_s.include?("://") ? database_name_or_url : city_database_url.call(database_name_or_url)
    # Com migrations_paths de cidade: o `define(version:)` do dump registra em
    # schema_migrations TODAS as versões de db/city_migrate até a do dump, não só
    # a última (sem isso, city:migrate tentaria recriar o schema).
    db_config = CitySchema.db_config_for(url)
    ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection(db_config) do
      ActiveRecord::Tasks::DatabaseTasks.load_schema(db_config, :ruby, schema_file)
    end
  end

  desc "Carrega db/city_schema.rb num banco (uso: city:load_schema[nome_ou_url])."
  task :load_schema, [:target] => :environment do |_t, args|
    target = args[:target].to_s
    target = ENV["CITY_DB"].to_s if target.empty?
    abort "uso: rails 'city:load_schema[nome_ou_url]' (ou CITY_DB=... rails city:load_schema)" if target.empty?

    load_city_schema.call(target)
    puts "[city:load_schema] OK — #{target}"
  end

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
      # Carrega (recarrega, se já carregado — o dump usa force: :cascade e é
      # idempotente) o schema limpo de cidade da Task 4. Só afeta as tabelas
      # que o próprio dump declara; `probes`, criada logo abaixo, nunca é
      # tocada por isso.
      load_city_schema.call(db)

      out, st = Open3.capture2e(env, *base, "-d", db, "-c",
        "CREATE TABLE IF NOT EXISTS probes (id serial PRIMARY KEY, label text NOT NULL)")
      abort "[city:test_databases] falha ao criar probes em #{db}:\n#{out}" unless st.success?
      puts "[city:test_databases] schema de cidade carregado em #{db}"
    end
    # #{no_city_selected_database} fica de propósito sem nenhuma tabela — ver
    # comentário acima. NÃO chame load_city_schema nem crie tabela alguma ali.
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

  # Cidades de desenvolvimento: duas, para o isolamento ser exercitável fora da
  # suíte (decisão do Plano 2). [slug, nome, uf].
  dev_cities = [ %w[curitiba Curitiba PR], [ "maringa", "Maringá", "PR" ] ].freeze

  desc "Dev: registra, cria o banco, carrega o schema e ativa uma cidade (idempotente). Uso: city:dev_up[slug,nome,uf]"
  task :dev_up, %i[slug name uf] => :environment do |_t, args|
    # Mesma razão de city:create: a database_url usa credencial de superusuário de
    # bootstrap. Provisionamento real (rota_provisioner) é o Plano 4.
    abort "[city:dev_up] só roda em development." unless Rails.env.development?
    abort "uso: rails 'city:dev_up[slug,nome,uf]'" if args[:slug].blank? || args[:name].blank?

    result = CityProvisioner.call(slug: args[:slug], name: args[:name], uf: args[:uf])
    abort "[city:dev_up] falhou: #{result.message}" if result.failure?
    city = result.payload[:city]

    database = ActiveRecord::Base.configurations.resolve(city.database_url).database.to_s
    abort "[city:dev_up] #{city.slug}: database_url sem database" if database.empty?

    su   = ENV.fetch("BOOTSTRAP_SUPERUSER", "rota_saude")
    pwd  = ENV.fetch("POSTGRES_PASSWORD") { abort "[city:dev_up] POSTGRES_PASSWORD ausente." }
    host = ENV.fetch("DATABASE_HOST", "127.0.0.1")
    port = ENV.fetch("DATABASE_PORT", "5432").to_s
    env  = { "PGPASSWORD" => pwd }
    base = [ "psql", "-h", host, "-p", port, "-U", su, "-v", "ON_ERROR_STOP=1", "-tA" ]

    exists, st = Open3.capture2e(env, *base, "-d", "postgres",
                                 "-c", "SELECT 1 FROM pg_database WHERE datname='#{database}'")
    abort "[city:dev_up] não consegui consultar pg_database:\n#{exists}" unless st.success?
    if exists.strip == "1"
      puts "[city:dev_up] #{database} já existe"
    else
      # Identificador entre aspas: slug pode ter hífen (rótulo DNS).
      out, st = Open3.capture2e(env, *base, "-d", "postgres", "-c", %(CREATE DATABASE "#{database}" OWNER #{su}))
      abort "[city:dev_up] falha ao criar #{database}:\n#{out}" unless st.success?
      puts "[city:dev_up] #{database} criado"
    end

    # O dump de cidade usa force: :cascade — só carrega num banco SEM o schema.
    # Se a checagem falhar, aborta: carregar às cegas apagaria dados.
    empty, st = Open3.capture2e(env, *base, "-d", database, "-c", "SELECT to_regclass('public.users') IS NULL")
    abort "[city:dev_up] não consegui checar o schema de #{database}:\n#{empty}" unless st.success?
    if empty.strip == "t"
      load_city_schema.call(database)
      puts "[city:dev_up] schema de cidade carregado em #{database}"
    else
      # Banco carregado antes de load_schema registrar todas as versões: completa
      # as anteriores à maior registrada (só INSERT) antes de migrar.
      CitySchema.backfill_versions!(city.database_url)
      puts "[city:dev_up] #{database} já tem o schema de cidade — versões anteriores registradas"
    end

    version = CitySchema.migrate!(city.database_url)
    city.update!(status: "active", schema_version: version.to_s)
    CityCatalog.reset_cache!
    puts "[city:dev_up] #{city.slug} → #{city.status} (#{database}, schema #{version})"
  end

  desc "Dev: sobe as cidades de desenvolvimento (curitiba, maringa). Idempotente."
  task dev_baseline: :environment do
    abort "[city:dev_baseline] só roda em development." unless Rails.env.development?

    dev_cities.each do |slug, name, uf|
      Rake::Task["city:dev_up"].reenable
      Rake::Task["city:dev_up"].invoke(slug, name, uf)
    end
  end

  desc "Aplica as migrations de cidade numa cidade do catálogo e registra a versão. Uso: city:migrate[slug]"
  task :migrate, %i[slug] => :environment do |_t, args|
    abort "uso: rails 'city:migrate[slug]'" if args[:slug].blank?
    city = City.find_by(slug: args[:slug])
    abort "[city:migrate] cidade #{args[:slug]} não existe" unless city
    abort "[city:migrate] cidade #{city.slug} está archived — não tem banco" if city.status == "archived"

    begin
      version = CityMigrations.run(city)
    rescue StandardError => e
      abort "[city:migrate] #{city.slug} falhou — #{e.class}: #{CitySchema.redact(e.message)}"
    end
    puts "[city:migrate] #{city.slug} → #{version}"
  end

  namespace :migrate do
    desc "Aplica as migrations de cidade em toda cidade active/suspended; sai com erro listando as que ficarem para trás."
    task all: :environment do
      CityMigrations.run_all
    rescue CityMigrations::Failed => e
      abort "[city:migrate:all] #{e.message}"
    end
  end

  # Ciclo de vida depois de ativa (Plano 4). Sem endpoint: o console só ganha tela
  # no Plano 6. Em produção rodam no papel worker (kamal app exec --roles=worker),
  # que tem PROVISIONER_DATABASE_URL e o volume de CITY_BACKUP_DIR.
  lifecycle_city = lambda do |task_name, slug|
    abort "uso: rails '#{task_name}[slug]'" if slug.blank?
    City.find_by(slug: slug) || abort("[#{task_name}] cidade #{slug} não existe")
  end
  city_backup_dir = -> { ENV.fetch("CITY_BACKUP_DIR") { Rails.root.join("tmp/city_backups").to_s } }

  desc "Suspende uma cidade (o host dela responde 403). Uso: city:suspend[slug]"
  task :suspend, %i[slug] => :environment do |_t, args|
    city = lifecycle_city.call("city:suspend", args[:slug])
    result = CityLifecycle::Suspend.call(city: city)
    abort "[city:suspend] #{result.reason}: #{result.message}" if result.failure?
    puts "[city:suspend] #{city.slug} → suspended"
  end

  desc "Retoma uma cidade suspensa. Uso: city:resume[slug]"
  task :resume, %i[slug] => :environment do |_t, args|
    city = lifecycle_city.call("city:resume", args[:slug])
    result = CityLifecycle::Resume.call(city: city)
    abort "[city:resume] #{result.reason}: #{result.message}" if result.failure?
    puts "[city:resume] #{city.slug} → active"
  end

  desc "Dump de uma cidade em CITY_BACKUP_DIR (default tmp/city_backups). Uso: city:backup[slug]"
  task :backup, %i[slug] => :environment do |_t, args|
    city = lifecycle_city.call("city:backup", args[:slug])
    result = CityLifecycle::Backup.call(city: city, dir: city_backup_dir.call)
    abort "[city:backup] #{result.reason}: #{result.message}" if result.failure?
    puts "[city:backup] #{city.slug} → #{result.payload[:path]}"
  end

  desc "IRREVERSÍVEL: dump final, archived, DROP DATABASE e DROP ROLE de uma cidade suspensa. Uso: CONFIRM=<slug> city:offboard[slug]"
  task :offboard, %i[slug] => :environment do |_t, args|
    city = lifecycle_city.call("city:offboard", args[:slug])
    abort "[city:offboard] irreversível: confirme com CONFIRM=#{city.slug}" unless ENV["CONFIRM"] == city.slug

    result = CityLifecycle::Offboard.call(city: city, backup_dir: city_backup_dir.call)
    abort "[city:offboard] #{result.reason}: #{result.message}" if result.failure?
    puts "[city:offboard] #{city.slug} → archived; banco e role apagados; dump final: " \
         "#{result.payload[:backup_path] || 'feito na execução anterior'}"
  end
end
