require "rails_helper"
require "rake"

# Ramos de city.rake que dependem de psql, de provisionamento ou de comandos de
# ciclo de vida. Nada aqui cria banco: Open3.capture2e, o load do schema
# (DatabaseTasks.with_temporary_connection) e os comandos são stubs — o que se
# prova é o contrato da task (argumentos, saída, abortos). O comportamento dos
# comandos está nos specs deles; o caminho real de city:load_schema está em
# city_rake_spec.rb.
RSpec.describe "city rake tasks (stubbed)" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("city:test_databases")
  end

  task_names = %w[
    city:test_databases city:create city:dev_up city:dev_baseline
    city:encrypt_message_phones city:encrypt_message_phones:all
    city:suspend city:resume city:backup city:restore city:resign_reports
  ]

  before { task_names.each { |name| Rake::Task[name].reenable } }

  def invoke(name, *args)
    original_stdout, $stdout = $stdout, StringIO.new
    original_stderr, $stderr = $stderr, StringIO.new
    status = nil
    begin
      Rake::Task[name].invoke(*args)
    rescue SystemExit => e
      status = e.status
    end
    [ $stdout.string, $stderr.string, status ]
  ensure
    $stdout = original_stdout
    $stderr = original_stderr
  end

  def status(ok) = instance_double(Process::Status, success?: ok)

  # Credenciais de bootstrap fixas, para provar os argumentos do psql.
  def stub_bootstrap_env
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("DATABASE_HOST", anything).and_return("db.spec")
    allow(ENV).to receive(:fetch).with("DATABASE_PORT", anything).and_return("6543")
    allow(ENV).to receive(:fetch).with("BOOTSTRAP_SUPERUSER", anything).and_return("su_spec")
    allow(ENV).to receive(:fetch).with("POSTGRES_PASSWORD").and_return("su-pwd")
  end

  let(:psql_calls) { [] }
  let(:base) { [ "psql", "-h", "db.spec", "-p", "6543", "-U", "su_spec", "-v", "ON_ERROR_STOP=1" ] }

  # Registra cada chamada e responde pelo bloco (argv -> [saída, ok?]).
  def stub_psql
    allow(Open3).to receive(:capture2e) do |env, *argv|
      psql_calls << [ env, argv ]
      output, ok = yield(argv)
      [ output, status(ok) ]
    end
  end

  # Bancos onde o load do schema de cidade teria rodado (sem conectar).
  def stub_schema_load
    loaded = []
    allow(ActiveRecord::Tasks::DatabaseTasks).to receive(:with_temporary_connection) do |db_config, &_block|
      loaded << db_config.database
    end
    loaded
  end

  describe "city:test_databases" do
    let(:city_dbs) { %w[rota_saude_test_city_a_spec rota_saude_test_city_b_spec] }
    let(:all_dbs) { city_dbs + [ "rota_saude_no_city_selected" ] }

    before do
      stub_bootstrap_env
      allow(ENV).to receive(:fetch).with(TestDatabaseSuffix::VARIABLE, "").and_return("_spec")
    end

    it "creates the missing databases, loads the city schema and creates probes only in the city ones" do
      stub_psql { |argv| [ argv.include?("-tA") ? "\n" : "OK\n", true ] }
      loaded = stub_schema_load

      out, _, exit_status = invoke("city:test_databases")

      expect(exit_status).to be_nil
      expect(psql_calls.map(&:first)).to all(eq("PGPASSWORD" => "su-pwd"))
      argvs = psql_calls.map(&:last)
      expect(argvs).to all(start_with(*base))
      creates = argvs.map(&:last).grep(/\ACREATE DATABASE/)
      expect(creates).to eq(all_dbs.map { |db| "CREATE DATABASE #{db} OWNER su_spec" })
      probes = argvs.select { |a| a.last.include?("CREATE TABLE IF NOT EXISTS probes") }
      expect(probes.map { |a| a[a.index("-d") + 1] }).to eq(city_dbs)
      # O banco de "nenhuma cidade" fica sem tabela alguma — nunca recebe o schema.
      expect(loaded).to eq(city_dbs)
      all_dbs.each { |db| expect(out).to include("[city:test_databases] #{db} criado") }
      city_dbs.each { |db| expect(out).to include("schema de cidade carregado em #{db}") }
    end

    it "skips creating databases that already exist, but still reloads the schema" do
      stub_psql { |argv| [ argv.include?("-tA") ? "1\n" : "OK\n", true ] }
      loaded = stub_schema_load

      out, _, exit_status = invoke("city:test_databases")

      expect(exit_status).to be_nil
      expect(psql_calls.map { |_, a| a.last }.grep(/\ACREATE DATABASE/)).to be_empty
      expect(loaded).to eq(city_dbs)
      all_dbs.each { |db| expect(out).to include("[city:test_databases] #{db} já existe") }
    end

    it "aborts with psql's output when CREATE DATABASE fails, loading no schema" do
      stub_psql do |argv|
        argv.include?("-tA") ? [ "\n", true ] : [ "ERROR: permission denied\n", false ]
      end
      loaded = stub_schema_load

      _, err, exit_status = invoke("city:test_databases")

      expect(exit_status).to eq(1)
      expect(err).to include("[city:test_databases] falha ao criar #{city_dbs.first}:\nERROR: permission denied")
      expect(loaded).to be_empty
    end

    it "aborts when creating probes fails" do
      stub_psql do |argv|
        next [ "1\n", true ] if argv.include?("-tA")
        [ "ERROR: probes\n", false ]
      end
      stub_schema_load

      _, err, exit_status = invoke("city:test_databases")

      expect(exit_status).to eq(1)
      expect(err).to include("[city:test_databases] falha ao criar probes em #{city_dbs.first}:\nERROR: probes")
    end

    it "aborts without running psql when POSTGRES_PASSWORD is missing" do
      allow(ENV).to receive(:fetch).with("POSTGRES_PASSWORD") { |_key, &fallback| fallback.call }
      allow(Open3).to receive(:capture2e)

      _, err, exit_status = invoke("city:test_databases")

      expect(exit_status).to eq(1)
      expect(err).to include("[city:test_databases] POSTGRES_PASSWORD ausente.")
      expect(Open3).not_to have_received(:capture2e)
    end

    it "aborts on an invalid ROTA_TEST_DB_SUFFIX before running psql (the name goes raw into CREATE DATABASE)" do
      allow(ENV).to receive(:fetch).with(TestDatabaseSuffix::VARIABLE, "").and_return("x; DROP")
      allow(Open3).to receive(:capture2e)

      _, err, exit_status = invoke("city:test_databases")

      expect(exit_status).to eq(1)
      expect(err).to include("[city:test_databases] ROTA_TEST_DB_SUFFIX=\"x; DROP\" inválido")
      expect(Open3).not_to have_received(:capture2e)
    end
  end

  describe "city:create" do
    before { allow(Rails.env).to receive(:development?).and_return(true) }

    it "registers the city and prints its URL with the password masked" do
      city = instance_double(City, slug: "novacidade", status: "provisioning",
                                   database_url: "postgres://rota_city:segredo@db:5432/rota_city_novacidade")
      expect(CityProvisioner).to receive(:call).with(slug: "novacidade", name: "Nova Cidade", uf: "PR")
        .and_return(Result.ok(city: city))

      out, _, exit_status = invoke("city:create", "novacidade", "Nova Cidade", "PR")

      expect(exit_status).to be_nil
      expect(out).to include("[city:create] novacidade → provisioning (postgres://rota_city:***@db:5432/rota_city_novacidade)")
      expect(out).not_to include("segredo")
    end

    it "aborts with the provisioner's message when it fails" do
      allow(CityProvisioner).to receive(:call).and_return(Result.fail(:invalid, message: "slug em uso"))

      _, err, exit_status = invoke("city:create", "repetida", "Repetida", "PR")

      expect(exit_status).to eq(1)
      expect(err).to include("[city:create] falhou: slug em uso")
    end

    it "prints the usage without a name, calling nothing" do
      expect(CityProvisioner).not_to receive(:call)

      _, err, exit_status = invoke("city:create", "semnome")

      expect(exit_status).to eq(1)
      expect(err).to include("uso: rails 'city:create[slug,nome,uf]'")
    end
  end

  describe "city:dev_up" do
    let(:database) { "rota_city_devupspec" }
    let!(:city) do
      create(:city, status: "provisioning", schema_version: "0",
                    database_url: "postgres://rota_city:rota_city@db:5432/#{database}")
    end
    let(:dev_base) { base + [ "-tA" ] }

    before do
      allow(Rails.env).to receive(:development?).and_return(true)
      stub_bootstrap_env
      allow(CityProvisioner).to receive(:call).and_return(Result.ok(city: city))
    end

    it "creates the database, loads the schema into an empty one, migrates and activates the city" do
      stub_psql do |argv|
        sql = argv.last
        next [ "\n", true ] if sql.start_with?("SELECT 1 FROM pg_database")
        next [ "t\n", true ] if sql.include?("to_regclass")
        [ "CREATE DATABASE\n", true ]
      end
      loaded = stub_schema_load
      expect(CitySchema).not_to receive(:backfill_versions!)
      expect(CitySchema).to receive(:migrate!).with(city.database_url).and_return(20_261_021_000_001)
      expect(CityCatalog).to receive(:reset_cache!).and_call_original

      out, _, exit_status = invoke("city:dev_up", city.slug, city.name, "PR")

      expect(exit_status).to be_nil
      expect(CityProvisioner).to have_received(:call).with(slug: city.slug, name: city.name, uf: "PR")
      argvs = psql_calls.map(&:last)
      expect(argvs[0]).to eq(dev_base + [ "-d", "postgres", "-c", "SELECT 1 FROM pg_database WHERE datname='#{database}'" ])
      # Identificador entre aspas: slug pode ter hífen.
      expect(argvs[1]).to eq(dev_base + [ "-d", "postgres", "-c", %(CREATE DATABASE "#{database}" OWNER su_spec) ])
      expect(argvs[2]).to eq(dev_base + [ "-d", database, "-c", "SELECT to_regclass('public.users') IS NULL" ])
      expect(loaded).to eq([ database ])
      expect(city.reload).to have_attributes(status: "active", schema_version: "20261021000001")
      expect(out).to include("[city:dev_up] #{database} criado")
      expect(out).to include("[city:dev_up] schema de cidade carregado em #{database}")
      expect(out).to include("[city:dev_up] #{city.slug} → active (#{database}, schema 20261021000001)")
    end

    # O dump usa force: :cascade — banco com schema nunca recebe o load.
    it "backfills the versions instead of reloading when the database already has the schema" do
      stub_psql do |argv|
        sql = argv.last
        next [ "1\n", true ] if sql.start_with?("SELECT 1 FROM pg_database")
        next [ "f\n", true ] if sql.include?("to_regclass")
        raise "psql inesperado: #{argv.inspect}"
      end
      loaded = stub_schema_load
      expect(CitySchema).to receive(:backfill_versions!).with(city.database_url).ordered
      expect(CitySchema).to receive(:migrate!).with(city.database_url).ordered.and_return(7)

      out, _, exit_status = invoke("city:dev_up", city.slug, city.name, "PR")

      expect(exit_status).to be_nil
      expect(loaded).to be_empty
      expect(out).to include("[city:dev_up] #{database} já existe")
      expect(out).to include("já tem o schema de cidade — versões anteriores registradas")
      expect(city.reload.status).to eq("active")
    end

    it "aborts when pg_database cannot be queried" do
      stub_psql { [ "could not connect\n", false ] }
      expect(CitySchema).not_to receive(:migrate!)

      _, err, exit_status = invoke("city:dev_up", city.slug, city.name, "PR")

      expect(exit_status).to eq(1)
      expect(err).to include("[city:dev_up] não consegui consultar pg_database:\ncould not connect")
      expect(city.reload.status).to eq("provisioning")
    end

    it "aborts when CREATE DATABASE fails" do
      stub_psql { |argv| argv.last.start_with?("SELECT") ? [ "\n", true ] : [ "ERROR: create\n", false ] }

      _, err, exit_status = invoke("city:dev_up", city.slug, city.name, "PR")

      expect(exit_status).to eq(1)
      expect(err).to include("[city:dev_up] falha ao criar #{database}:\nERROR: create")
    end

    # Carregar às cegas apagaria dados: sem saber se há schema, não carrega.
    it "aborts without loading the schema when the schema check fails" do
      stub_psql { |argv| argv.last.include?("to_regclass") ? [ "ERROR: check\n", false ] : [ "1\n", true ] }
      loaded = stub_schema_load
      expect(CitySchema).not_to receive(:backfill_versions!)

      _, err, exit_status = invoke("city:dev_up", city.slug, city.name, "PR")

      expect(exit_status).to eq(1)
      expect(err).to include("[city:dev_up] não consegui checar o schema de #{database}:\nERROR: check")
      expect(loaded).to be_empty
    end

    it "aborts with the provisioner's message when it fails, running no psql" do
      allow(CityProvisioner).to receive(:call).and_return(Result.fail(:invalid, message: "uf inválida"))
      allow(Open3).to receive(:capture2e)

      _, err, exit_status = invoke("city:dev_up", city.slug, city.name, "XX")

      expect(exit_status).to eq(1)
      expect(err).to include("[city:dev_up] falhou: uf inválida")
      expect(Open3).not_to have_received(:capture2e)
    end

    it "aborts when the city's database_url has no database" do
      city.update!(database_url: "postgres://rota_city:rota_city@db:5432")
      allow(Open3).to receive(:capture2e)

      _, err, exit_status = invoke("city:dev_up", city.slug, city.name, "PR")

      expect(exit_status).to eq(1)
      expect(err).to include("[city:dev_up] #{city.slug}: database_url sem database")
      expect(Open3).not_to have_received(:capture2e)
    end

    it "aborts when POSTGRES_PASSWORD is missing" do
      allow(ENV).to receive(:fetch).with("POSTGRES_PASSWORD") { |_key, &fallback| fallback.call }
      allow(Open3).to receive(:capture2e)

      _, err, exit_status = invoke("city:dev_up", city.slug, city.name, "PR")

      expect(exit_status).to eq(1)
      expect(err).to include("[city:dev_up] POSTGRES_PASSWORD ausente.")
      expect(Open3).not_to have_received(:capture2e)
    end

    it "prints the usage without a name, calling nothing" do
      _, err, exit_status = invoke("city:dev_up", "semnome")

      expect(exit_status).to eq(1)
      expect(CityProvisioner).not_to have_received(:call)
      expect(err).to include("uso: rails 'city:dev_up[slug,nome,uf]'")
    end
  end

  describe "city:dev_baseline" do
    it "re-enables and invokes city:dev_up for each development city, in order" do
      allow(Rails.env).to receive(:development?).and_return(true)
      dev_up = Rake::Task["city:dev_up"]
      expect(dev_up).to receive(:reenable).twice
      expect(dev_up).to receive(:invoke).with("curitiba", "Curitiba", "PR").ordered
      expect(dev_up).to receive(:invoke).with("maringa", "Maringá", "PR").ordered

      _, _, exit_status = invoke("city:dev_baseline")

      expect(exit_status).to be_nil
    end
  end

  # Sem banco de cidade de verdade: CityConnection.with é stub que só guarda a
  # cidade em que o bloco rodaria.
  describe "city:encrypt_message_phones" do
    let(:entered) { [] }

    before do
      allow(CityConnection).to receive(:with) do |city, &block|
        entered << city.slug
        block.call
      end
    end

    it "encrypts the phones of one city inside its connection and prints the counts" do
      city = create(:city, status: "active")
      expect(CityLifecycle::EncryptMessagePhones).to receive(:call)
        .and_return("InboundMessage" => 3, "OutboundMessage" => 0)

      out, _, exit_status = invoke("city:encrypt_message_phones", city.slug)

      expect(exit_status).to be_nil
      expect(entered).to eq([ city.slug ])
      expect(out).to include("[city:encrypt_message_phones] #{city.slug}: InboundMessage=3 OutboundMessage=0")
    end

    it "refuses an archived city, an unknown slug and a blank slug, calling nothing" do
      archived = create(:city, status: "archived")
      expect(CityLifecycle::EncryptMessagePhones).not_to receive(:call)

      _, err, exit_status = invoke("city:encrypt_message_phones", archived.slug)
      expect(exit_status).to eq(1)
      expect(err).to include("cidade #{archived.slug} está archived — não tem banco")

      Rake::Task["city:encrypt_message_phones"].reenable
      _, err, exit_status = invoke("city:encrypt_message_phones", "naoexiste")
      expect(exit_status).to eq(1)
      expect(err).to include("[city:encrypt_message_phones] cidade naoexiste não existe")

      Rake::Task["city:encrypt_message_phones"].reenable
      _, err, exit_status = invoke("city:encrypt_message_phones")
      expect(exit_status).to eq(1)
      expect(err).to include("uso: rails 'city:encrypt_message_phones[slug]'")
      expect(entered).to be_empty
    end

    describe ":all" do
      let!(:active) { create(:city, slug: "encaaa#{SecureRandom.hex(2)}", status: "active") }
      let!(:suspended) { create(:city, slug: "encbbb#{SecureRandom.hex(2)}", status: "suspended") }
      let!(:provisioning) { create(:city, slug: "encccc#{SecureRandom.hex(2)}", status: "provisioning") }

      it "runs every active/suspended city in slug order, skipping the others" do
        allow(CityLifecycle::EncryptMessagePhones).to receive(:call) { { "InboundMessage" => 1 } }

        out, _, exit_status = invoke("city:encrypt_message_phones:all")

        expect(exit_status).to be_nil
        expect(entered).to include(active.slug, suspended.slug)
        expect(entered).not_to include(provisioning.slug)
        expect(entered).to eq(entered.sort)
        expect(out).to include("[city:encrypt_message_phones:all] #{active.slug}: InboundMessage=1")
        expect(out).to include("[city:encrypt_message_phones:all] #{suspended.slug}: InboundMessage=1")
      end

      # Uma cidade que falha não para as outras; a task sai com erro listando-a.
      it "keeps going after a failing city and aborts listing it, logging only the error class" do
        allow(CityLifecycle::EncryptMessagePhones).to receive(:call) do
          raise ActiveRecord::StatementInvalid, "segredo no texto" if entered.last == active.slug
          { "InboundMessage" => 2 }
        end

        out, err, exit_status = invoke("city:encrypt_message_phones:all")

        expect(exit_status).to eq(1)
        expect(out).to include("[city:encrypt_message_phones:all] #{suspended.slug}: InboundMessage=2")
        expect(err).to include("[city:encrypt_message_phones:all] #{active.slug} falhou — ActiveRecord::StatementInvalid")
        expect(err).not_to include("segredo no texto")
        expect(err).to include("[city:encrypt_message_phones:all] falharam: #{active.slug}")
      end
    end
  end

  describe "lifecycle tasks" do
    let!(:city) { create(:city, status: "suspended") }

    it "city:suspend prints the new status on success" do
      expect(CityLifecycle::Suspend).to receive(:call).with(city: city).and_return(Result.ok)

      out, _, exit_status = invoke("city:suspend", city.slug)

      expect(exit_status).to be_nil
      expect(out).to include("[city:suspend] #{city.slug} → suspended")
    end

    it "city:resume prints the new status on success and aborts with reason and message on failure" do
      expect(CityLifecycle::Resume).to receive(:call).with(city: city).and_return(Result.ok)
      out, _, exit_status = invoke("city:resume", city.slug)
      expect(exit_status).to be_nil
      expect(out).to include("[city:resume] #{city.slug} → active")

      Rake::Task["city:resume"].reenable
      allow(CityLifecycle::Resume).to receive(:call).and_return(Result.fail(:not_suspended, message: "já ativa"))
      _, err, exit_status = invoke("city:resume", city.slug)
      expect(exit_status).to eq(1)
      expect(err).to include("[city:resume] not_suspended: já ativa")
    end

    it "city:backup dumps into CITY_BACKUP_DIR and prints the dump and digest paths" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("CITY_BACKUP_DIR").and_return("/backups/spec")
      expect(CityLifecycle::Backup).to receive(:call).with(city: city, dir: "/backups/spec")
        .and_return(Result.ok(path: "/backups/spec/x.dump", key_digest_path: "/backups/spec/x.sha256"))

      out, _, exit_status = invoke("city:backup", city.slug)

      expect(exit_status).to be_nil
      expect(out).to include("[city:backup] #{city.slug} → /backups/spec/x.dump (digest: /backups/spec/x.sha256)")
    end

    it "city:backup defaults to tmp/city_backups and aborts with reason and message on failure" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("CITY_BACKUP_DIR") { |_key, &fallback| fallback.call }
      expect(CityLifecycle::Backup).to receive(:call).with(city: city, dir: Rails.root.join("tmp/city_backups").to_s)
        .and_return(Result.fail(:pg_dump_failed, message: "pg_dump saiu 1"))

      _, err, exit_status = invoke("city:backup", city.slug)

      expect(exit_status).to eq(1)
      expect(err).to include("[city:backup] pg_dump_failed: pg_dump saiu 1")
    end

    it "city:restore restores the given dump and prints only its basename" do
      expect(CityLifecycle::Restore).to receive(:call).with(city: city, path: "/backups/spec/cidade.dump")
        .and_return(Result.ok)

      out, _, exit_status = invoke("city:restore", city.slug, "/backups/spec/cidade.dump")

      expect(exit_status).to be_nil
      expect(out).to include("[city:restore] #{city.slug} ← cidade.dump")
    end

    it "city:restore prints the usage without a path and aborts with reason and message on failure" do
      expect(CityLifecycle::Restore).not_to receive(:call).with(city: city, path: nil)
      _, err, exit_status = invoke("city:restore", city.slug)
      expect(exit_status).to eq(1)
      expect(err).to include("uso: rails 'city:restore[slug,/caminho/do.dump]'")

      Rake::Task["city:restore"].reenable
      allow(CityLifecycle::Restore).to receive(:call).and_return(Result.fail(:not_suspended, message: "cidade ativa"))
      _, err, exit_status = invoke("city:restore", city.slug, "/x.dump")
      expect(exit_status).to eq(1)
      expect(err).to include("[city:restore] not_suspended: cidade ativa")
    end

    it "city:resign_reports re-signs inside the city's connection and prints the count" do
      entered = []
      allow(CityConnection).to receive(:with) { |c, &block| entered << c.slug; block.call }
      expect(CityReports::Resign).to receive(:call).and_return(Result.ok(count: 4))

      out, _, exit_status = invoke("city:resign_reports", city.slug)

      expect(exit_status).to be_nil
      expect(entered).to eq([ city.slug ])
      expect(out).to include("[city:resign_reports] #{city.slug} → 4 assinatura(s)")
    end

    it "city:resign_reports aborts with reason and message on failure" do
      allow(CityConnection).to receive(:with) { |_c, &block| block.call }
      allow(CityReports::Resign).to receive(:call).and_return(Result.fail(:missing_key, message: "sem chave"))

      _, err, exit_status = invoke("city:resign_reports", city.slug)

      expect(exit_status).to eq(1)
      expect(err).to include("[city:resign_reports] missing_key: sem chave")
    end
  end
end
