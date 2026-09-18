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
  # eles. Saíram de database.yml, e o `rota_saude_development` foi APAGADO em
  # 2026-09-16 (dump guardado fora do repo). A lista permanece de propósito: ela
  # compara NOMES, sem consultar o Postgres, e o que ela protege é o caso de
  # alguém recriar um banco com um desses nomes — aí city:load_schema precisa
  # seguir recusando. `rota_saude_test` continua existindo (recriado vazio).
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
      # O dump em Ruby não representa trigger (db/city_triggers.sql, cabeçalho).
      ActiveRecord::Base.connection.execute(File.read(Rails.root.join("db/city_triggers.sql")))
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

  # M6 (rodada de hardening, review): a linha de confirmação de
  # city:invite_admin precisa dar contexto (para quem foi) sem ecoar o e-mail
  # inteiro em log/terminal — só o primeiro caractere + "***" + domínio, ex.:
  # "p***@cidade.gov.br". Só usada aqui; não vira utilitário global porque
  # nenhum outro chamador precisa disso hoje.
  mask_email = lambda do |address|
    local, _, domain = address.to_s.partition("@")
    "#{local[0]}***@#{domain}"
  end

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
    puts "[city:backup] #{city.slug} → #{result.payload[:path]} (digest: #{result.payload[:key_digest_path]})"
  end

  desc "Restaura um dump numa cidade suspensa. Uso: city:restore[slug,caminho]"
  task :restore, %i[slug path] => :environment do |_t, args|
    city = lifecycle_city.call("city:restore", args[:slug])
    abort "uso: rails 'city:restore[slug,/caminho/do.dump]'" if args[:path].blank?

    result = CityLifecycle::Restore.call(city: city, path: args[:path])
    abort "[city:restore] #{result.reason}: #{result.message}" if result.failure?
    puts "[city:restore] #{city.slug} ← #{File.basename(args[:path])}"
  end

  desc "Reescreve as assinaturas de relatório de uma cidade com a chave dela. Uso: city:resign_reports[slug]"
  task :resign_reports, %i[slug] => :environment do |_t, args|
    city = lifecycle_city.call("city:resign_reports", args[:slug])
    result = CityConnection.with(city) { CityReports::Resign.call }
    abort "[city:resign_reports] #{result.reason}: #{result.message}" if result.failure?
    puts "[city:resign_reports] #{city.slug} → #{result.payload[:count]} assinatura(s)"
  end

  # Plano 7: migração e rotação de chave de cifra de uma cidade.
  #
  # A cidade precisa estar SUSPENSA: entre ler uma linha com o material antigo e
  # gravá-la com o novo, uma busca determinística de outro processo (webhook,
  # job) usaria a chave errada e não acharia a linha.
  # Runbook: city:backup → city:suspend → city:rekey → city:resume
  desc "Migra uma cidade suspensa da chave da plataforma (pré-Plano-7) para a chave dela. Uso: city:rekey[slug]"
  task :rekey, %i[slug] => :environment do |_t, args|
    city = lifecycle_city.call("city:rekey", args[:slug])
    unless city.status == "suspended"
      abort "[city:rekey] cidade #{city.slug} precisa estar suspensa (status=#{city.status}) — rode city:backup e city:suspend antes"
    end

    # Fix F1: suspensão sozinha não basta — outro processo web pode ainda
    # servir a cidade como ativa por até CityLifecycle::SuspensionGuard::QUIET_PERIOD
    # (ver esse módulo). city:rekey não move o material do catálogo, mas
    # continua vulnerável ao lado determinístico: uma escrita concorrente sob a
    # chave global cria uma segunda linha que o índice único não pega, porque
    # os ciphertexts divergem. Recusar aqui é mais barato do que confiar
    # "cidade suspensa é suficiente" e deixar duas tasks vizinhas com regras
    # diferentes para a mesma corrida.
    if CityLifecycle::SuspensionGuard.suspended_recently?(city)
      abort "[city:rekey] cidade #{city.slug} suspensa recentemente — aguarde " \
            "#{CityLifecycle::SuspensionGuard::QUIET_PERIOD.to_i} s depois do city:suspend antes de rodar city:rekey"
    end

    # source: :platform — os dados de uma cidade ainda não migrada estão em
    # ciphertext da chave GLOBAL (o que já existia antes deste plano), não da
    # própria cidade. Por isso NÃO passamos from_key: aqui — com
    # source: :platform o serviço recusa a combinação com ArgumentError, porque
    # a origem já é a chave global, não um material arbitrário.
    result = CityRekey.call(city: city, source: :platform)
    abort "[city:rekey] #{result.reason}: #{result.message}" if result.failure?
    puts "[city:rekey] #{city.slug} → #{result.payload[:counts].map { |m, n| "#{m}=#{n}" }.join(' ')}"
  end

  desc "Gera material NOVO para uma cidade suspensa e reescreve os dados. Uso: city:rotate_key[slug]"
  task :rotate_key, %i[slug] => :environment do |_t, args|
    city = lifecycle_city.call("city:rotate_key", args[:slug])
    abort "[city:rotate_key] cidade #{city.slug} precisa estar suspensa (status=#{city.status})" unless city.status == "suspended"

    # Fix F1 (o Critical desta rodada): a mesma checagem de city:rekey acima,
    # ANTES de gerar/gravar material novo. Aqui a corrida é mais grave: um
    # outro processo que ainda serve a cidade como ativa escreveria sob o
    # material ANTIGO enquanto este processo já reescreveu tudo sob o NOVO —
    # ver CityLifecycle::SuspensionGuard para o porquê do TTL duas vezes.
    if CityLifecycle::SuspensionGuard.suspended_recently?(city)
      abort "[city:rotate_key] cidade #{city.slug} suspensa recentemente — aguarde " \
            "#{CityLifecycle::SuspensionGuard::QUIET_PERIOD.to_i} s depois do city:suspend antes de rodar city:rotate_key"
    end

    previous = city.encryption_key
    city.update!(encryption_key: SecureRandom.hex(32))

    # `from_key: previous` (origem :city, o padrão): a rotação lê pelo material
    # ANTERIOR da própria cidade, não pela chave global — diferente de
    # city:rekey acima. O catálogo já foi atualizado para o material NOVO antes
    # desta chamada (linha acima), então uma falha aqui deixa o catálogo
    # apontando para uma chave que os dados ainda não usam.
    #
    # O `update!` de restauração abaixo NÃO desfaz nenhuma linha reescrita —
    # quem garante tudo-ou-nada é a transação única dentro de CityRekey (zero
    # linhas mudam numa falha). O papel dele é mais estreito: devolver o
    # catálogo ao material que os dados de fato usam, já que a rotação grava o
    # material novo no catálogo ANTES de reescrever qualquer linha.
    result = CityRekey.call(city: city.reload, from_key: previous)
    if result.failure?
      # A restauração abaixo pode, ela mesma, falhar (ex.: validação, conexão).
      # Sem capturar isso, o operador veria só o abort da linha de baixo e
      # acreditaria que o catálogo voltou para `previous` quando na verdade
      # ainda aponta para o material novo — o catálogo dizendo uma chave que os
      # dados não usam, exatamente o estado que este parágrafo inteiro existe
      # para evitar, e sem mais nenhuma tentativa de correção automática depois
      # disso. Por isso: nem retry, nem rescue-and-continue — só uma mensagem
      # legível com o que de fato aconteceu e o slug afetado, para o operador
      # corrigir o catálogo à mão. Nunca o material em si, nem `e.message`
      # (que pode citar o valor do atributo em erros de validação) — só a
      # classe da exceção e o slug.
      begin
        city.update!(encryption_key: previous)
      rescue StandardError => e
        abort "[city:rotate_key] #{city.slug}: rewrite falhou (#{result.reason}) E a restauração do catálogo " \
              "também falhou (#{e.class}) — os DADOS NÃO foram reescritos (a transação de CityRekey desfez tudo; " \
              "as linhas continuam sob o material ANTIGO), mas o CATÁLOGO agora guarda o material NOVO, que os " \
              "dados não usam. Corrija o encryption_key de #{city.slug} manualmente antes de rodar city:rekey ou " \
              "city:rotate_key nesta cidade de novo."
      end
      abort "[city:rotate_key] #{result.reason}: #{result.message} — material anterior restaurado no catálogo"
    end

    # Fix F2 (rodada final de revisão): report_snapshots.signature deriva do
    # encryption_key da cidade (CityEncryption.report_signing_key), mas não é
    # um `encrypts` — CityRekey::TARGETS não o cobre. Sem este passo, todo
    # snapshot assinado com o material ANTERIOR fica órfão: nem a chave nova
    # (mudou) nem a legada global (nunca foi essa) batem, e
    # ReportSnapshot.find_by_signed_token devolve nil — /r/:token 404 para
    # todo link de cidadão dos últimos 30 dias, sem nada no log dizendo
    # por quê. A rotação dos DADOS já terminou (result.success? acima); o que
    # falta é só a assinatura dos relatórios já emitidos, então isto roda
    # depois, com a chave NOVA já valendo (CityConnection.with usa
    # city.encryption_key atual).
    resign_result = CityConnection.with(city) { CityReports::Resign.call }
    if resign_result.failure?
      # Fail loudly, sem tentativa de correção automática: os DADOS já foram
      # reescritos com sucesso sob o material novo (não há o que desfazer
      # aqui, ao contrário do bloco de falha do CityRekey acima) — mas o
      # operador precisa saber que a rotação NÃO terminou de verdade antes de
      # liberar a cidade (city:resume), porque links de relatório vão 404 até
      # que city:resign_reports rode com sucesso.
      abort "[city:rotate_key] #{city.slug}: chave rotacionada com sucesso " \
            "(#{result.payload[:counts].map { |m, n| "#{m}=#{n}" }.join(' ')}), MAS o re-sign dos relatórios " \
            "FALHOU (#{resign_result.reason}: #{resign_result.message}) — links de relatório assinados com o " \
            "material anterior vão responder 404 até você rodar 'rails city:resign_reports[#{city.slug}]' com " \
            "sucesso. NÃO libere a cidade (city:resume) antes disso."
    end

    Platform.audit("city.key_rotated", city_id: city.id)
    puts "[city:rotate_key] #{city.slug} → #{result.payload[:counts].map { |m, n| "#{m}=#{n}" }.join(' ')} " \
         "report_signatures=#{resign_result.payload[:count]}"
  end

  # Reenvia o convite do primeiro municipal_admin de uma cidade JÁ active
  # (rodada de hardening, pre-Plano 6): cobre quem perdeu a janela de 7 dias do
  # convite original — depois que a cidade vira active, o guard no início de
  # ProvisionCityJob#perform corta o reenvio automático de lá. Uma cidade em
  # provisioning é tratada pelo próprio job (retry reenvia o mesmo token); esta
  # task recusa esse caso para não duplicar a lógica.
  desc "Reenvia o convite do primeiro municipal_admin de uma cidade active. Uso: city:invite_admin[slug,email]"
  task :invite_admin, %i[slug email] => :environment do |_t, args|
    city = lifecycle_city.call("city:invite_admin", args[:slug])
    unless city.status == "active"
      abort "[city:invite_admin] cidade #{city.slug} não está active (status=#{city.status}) — uma cidade em " \
            "provisioning é reenviada pelo próprio ProvisionCityJob, não por esta task"
    end

    email = args[:email].to_s
    abort "uso: rails 'city:invite_admin[slug,email]'" if email.blank?
    abort "[city:invite_admin] e-mail inválido" unless email.match?(URI::MailTo::EMAIL_REGEXP)

    result = CityLifecycle::InviteAdmin.call(city: city, email: email)
    abort "[city:invite_admin] #{result.reason}: #{result.message}" if result.failure?

    InvitationMailer.invite(**result.payload[:mail_args]).deliver_later
    Platform.audit("city.admin_reinvited", city_id: city.id, invitation_id: result.payload[:invitation_id])
    puts "[city:invite_admin] #{city.slug} → convite reenviado (#{mask_email.call(email)})"
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
