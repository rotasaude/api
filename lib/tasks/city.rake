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
  # schema de cidade: primary/queue/cache são o banco compartilhado (só
  # fila/cache, até o Plano 5), platform é o catálogo/roteamento entre
  # cidades, e city_unset é o banco deliberadamente-vazio que faz o shard
  # `bootstrap` falhar fechado (ver comentário de no_city_selected_database
  # acima) — carregar QUALQUER coisa nele destruiria essa garantia. O config
  # `admin` saiu de database.yml no corte do Plano 2 (Task 5); o nome segue na
  # lista só como defesa, caso uma config com esse nome reapareça.
  protected_role_names = %w[primary admin queue cache platform city_unset].freeze

  # Bancos protegidos em TODO ambiente declarado em database.yml (development,
  # test, production, ...) — não só o Rails.env corrente. `configurations`
  # devolve um DatabaseConfig por (ambiente, nome); filtramos pelo nome do
  # role e pegamos o `database` resolvido, ignorando entradas sem banco
  # resolvível (ex.: production sem DATABASE_URL setada neste container).
  protected_database_names = lambda do
    ActiveRecord::Base.configurations.configurations
      .select { |cfg| protected_role_names.include?(cfg.name) }
      .filter_map { |cfg| cfg.respond_to?(:database) ? cfg.database.presence : nil }
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
  # em config/database.yml. Isso é deliberado: primary/admin apontam para o
  # banco compartilhado, e um role `city` ali correria o risco de qualquer
  # `db:migrate`/`db:prepare` genérico tentar alcançá-lo. with_temporary_connection
  # troca a conexão de ActiveRecord::Base só durante o load e restaura a
  # original (o banco compartilhado) no `ensure`, então esta task nunca toca
  # primary/admin/queue/cache.
  #
  # GUARDA (I6 do code review): a dump usa force: :cascade — um alvo errado
  # dropa e recria tabelas de domínio de verdade. Por isso, antes de tocar
  # em qualquer conexão: só development/test, e nunca um alvo que resolva
  # para o banco de primary/admin/queue/cache/platform/city_unset.
  load_city_schema = lambda do |database_name_or_url|
    unless Rails.env.development? || Rails.env.test?
      abort "[city] city:load_schema só roda em development/test (env atual: #{Rails.env})."
    end

    target_database = resolve_database_name.call(database_name_or_url)
    if protected_database_names.call.include?(target_database)
      abort "[city] recusado: #{target_database.inspect} é o banco de primary/admin/queue/cache/platform/city_unset — " \
            "city:load_schema nunca escreve lá (a dump usa force: :cascade)."
    end

    schema_file = Rails.root.join("db/city_schema.rb").to_s
    abort "[city] #{schema_file} não existe." unless File.exist?(schema_file)

    url = database_name_or_url.to_s.include?("://") ? database_name_or_url : city_database_url.call(database_name_or_url)
    db_config = ActiveRecord::Base.configurations.resolve(url)
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
end
