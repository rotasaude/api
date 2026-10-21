require "rails_helper"
require "rake"

# platform:bootstrap e platform:triggers rodam como superusuário contra o
# cluster — aqui nada chega ao Postgres: psql (Open3.capture2e) e PG.connect
# são stubs, e o que se prova é o contrato da task (argumentos, ordem, abortos).
RSpec.describe "platform rake tasks" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("platform:bootstrap")
  end

  before do
    %w[platform:bootstrap platform:triggers].each { |name| Rake::Task[name].reenable }
  end

  def invoke(name)
    original_stdout, $stdout = $stdout, StringIO.new
    original_stderr, $stderr = $stderr, StringIO.new
    status = nil
    begin
      Rake::Task[name].invoke
    rescue SystemExit => e
      status = e.status
    end
    [ $stdout.string, $stderr.string, status ]
  ensure
    $stdout = original_stdout
    $stderr = original_stderr
  end

  def status(ok) = instance_double(Process::Status, success?: ok)

  describe "platform:triggers" do
    let(:file) { Rails.root.join("db/platform_triggers.sql") }

    it "aborts when db/platform_triggers.sql is missing, executing nothing" do
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(file).and_return(false)
      expect(PlatformRecord.connection).not_to receive(:execute)

      _, err, exit_status = invoke("platform:triggers")

      expect(exit_status).to eq(1)
      expect(err).to include("[platform:triggers] #{file} não existe.")
    end

    it "executes the whole SQL file on the platform connection" do
      expect(PlatformRecord.connection).to receive(:execute).with(File.read(file))

      out, _, exit_status = invoke("platform:triggers")

      expect(exit_status).to be_nil
      expect(out).to include("[platform:triggers] instalados em #{PlatformRecord.connection.current_database}")
    end
  end

  describe "platform:bootstrap" do
    let(:platform_db) do
      ActiveRecord::Base.configurations.configs_for(env_name: Rails.env, name: "platform").database
    end
    let(:base) { [ "psql", "-h", "db.spec", "-p", "6543", "-U", "su_spec", "-v", "ON_ERROR_STOP=1" ] }
    let(:psql_calls) { [] }
    let(:conn) { instance_double(PG::Connection) }
    let(:role_lookup) { instance_double(PG::Result, ntuples: 1) }

    before do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("DATABASE_HOST", anything).and_return("db.spec")
      allow(ENV).to receive(:fetch).with("DATABASE_PORT", anything).and_return("6543")
      allow(ENV).to receive(:fetch).with("BOOTSTRAP_SUPERUSER", anything).and_return("su_spec")
      allow(ENV).to receive(:fetch).with("POSTGRES_PASSWORD").and_return("su-pwd")
      allow(ENV).to receive(:fetch).with("ROTA_PLATFORM_PASSWORD", anything).and_return("plat-pwd")
      allow(ENV).to receive(:fetch).with("ROTA_PROVISIONER_PASSWORD", anything).and_return("prov-pwd")

      allow(PG).to receive(:connect).and_return(conn)
      allow(conn).to receive(:set_notice_receiver)
      allow(conn).to receive(:encrypt_password).with("prov-pwd", "rota_provisioner", "scram-sha-256").and_return("SCRAM-SHA-256$x")
      allow(conn).to receive(:escape_literal).with("SCRAM-SHA-256$x").and_return("'SCRAM-SHA-256$x'")
      allow(conn).to receive(:exec_params)
        .with("SELECT 1 FROM pg_roles WHERE rolname = $1", [ "rota_provisioner" ]).and_return(role_lookup)
      allow(conn).to receive(:exec)
      allow(conn).to receive(:close)
    end

    # Responde a cada chamada do psql pelo SQL do -c; grava argv e env.
    def stub_psql(role_ok: true, db_exists: false, create_ok: true)
      allow(Open3).to receive(:capture2e) do |env, *argv|
        psql_calls << [ env, argv ]
        sql = argv.last
        if sql.include?("CREATE ROLE rota_platform")
          [ role_ok ? "DO\n" : "ERROR: permission denied\n", status(role_ok) ]
        elsif sql.start_with?("SELECT 1 FROM pg_database")
          [ db_exists ? "1\n" : "\n", status(true) ]
        elsif sql.start_with?("CREATE DATABASE")
          [ create_ok ? "CREATE DATABASE\n" : "ERROR: disk full\n", status(create_ok) ]
        else
          raise "psql inesperado: #{argv.inspect}"
        end
      end
    end

    it "creates the platform role, the provisioner role and the database with the superuser credentials" do
      stub_psql
      allow(role_lookup).to receive(:ntuples).and_return(0)

      out, _, exit_status = invoke("platform:bootstrap")

      expect(exit_status).to be_nil
      expect(psql_calls.map(&:first)).to all(eq("PGPASSWORD" => "su-pwd"))
      role_call, exists_call, create_call = psql_calls.map(&:last)
      expect(role_call.first(base.size)).to eq(base)
      expect(role_call[base.size, 2]).to eq([ "-d", "postgres" ])
      expect(role_call.last).to include("CREATE ROLE rota_platform LOGIN PASSWORD 'plat-pwd'")
      expect(exists_call).to eq(base + [ "-tA", "-d", "postgres", "-c", "SELECT 1 FROM pg_database WHERE datname='#{platform_db}'" ])
      expect(create_call).to eq(base + [ "-d", "postgres", "-c", "CREATE DATABASE #{platform_db} OWNER rota_platform" ])

      expect(PG).to have_received(:connect)
        .with(host: "db.spec", port: "6543", dbname: "postgres", user: "su_spec", password: "su-pwd")
      expect(conn).to have_received(:exec)
        .with("CREATE ROLE rota_provisioner LOGIN CREATEDB CREATEROLE INHERIT PASSWORD 'SCRAM-SHA-256$x'")
      expect(conn).to have_received(:close)
      expect(out).to include("[platform:bootstrap] #{platform_db} criado")
    end

    # A senha do provisioner vai cifrada (SCRAM): nunca em texto no SQL.
    it "alters an existing provisioner role, with INHERIT and NOSUPERUSER, never the plaintext password" do
      stub_psql(db_exists: true)

      out, _, exit_status = invoke("platform:bootstrap")

      expect(exit_status).to be_nil
      expect(conn).to have_received(:exec).once
        .with("ALTER ROLE rota_provisioner LOGIN CREATEDB CREATEROLE NOSUPERUSER INHERIT PASSWORD 'SCRAM-SHA-256$x'")
      expect(conn).not_to have_received(:exec).with(/prov-pwd/)
      expect(psql_calls.map { |_, argv| argv.last }).not_to include(a_string_starting_with("CREATE DATABASE"))
      expect(out).to include("[platform:bootstrap] #{platform_db} já existe")
    end

    it "aborts with psql's output when the platform role fails, before touching the provisioner" do
      stub_psql(role_ok: false)

      _, err, exit_status = invoke("platform:bootstrap")

      expect(exit_status).to eq(1)
      expect(err).to include("[platform:bootstrap] falha no role:\nERROR: permission denied")
      expect(PG).not_to have_received(:connect)
      expect(psql_calls.size).to eq(1)
    end

    it "aborts naming only the error class when the provisioner role fails, and still closes the connection" do
      stub_psql
      allow(conn).to receive(:exec).and_raise(PG::InsufficientPrivilege, "must be superuser prov-pwd")

      _, err, exit_status = invoke("platform:bootstrap")

      expect(exit_status).to eq(1)
      expect(err).to include("[platform:bootstrap] falha no role rota_provisioner: PG::InsufficientPrivilege")
      expect(err).not_to include("prov-pwd")
      expect(conn).to have_received(:close)
      expect(psql_calls.size).to eq(1)
    end

    it "aborts when PG.connect itself fails (no connection to close)" do
      stub_psql
      allow(PG).to receive(:connect).and_raise(PG::ConnectionBad)

      _, err, exit_status = invoke("platform:bootstrap")

      expect(exit_status).to eq(1)
      expect(err).to include("falha no role rota_provisioner: PG::ConnectionBad")
      expect(conn).not_to have_received(:close)
    end

    it "aborts with psql's output when CREATE DATABASE fails" do
      stub_psql(create_ok: false)

      out, err, exit_status = invoke("platform:bootstrap")

      expect(exit_status).to eq(1)
      expect(err).to include("[platform:bootstrap] falha ao criar #{platform_db}:\nERROR: disk full")
      expect(out).not_to include("criado")
    end

    it "aborts without running psql when POSTGRES_PASSWORD is missing" do
      allow(ENV).to receive(:fetch).with("POSTGRES_PASSWORD") { |_key, &fallback| fallback.call }
      allow(Open3).to receive(:capture2e)

      _, err, exit_status = invoke("platform:bootstrap")

      expect(exit_status).to eq(1)
      expect(err).to include("[platform:bootstrap] POSTGRES_PASSWORD ausente.")
      expect(Open3).not_to have_received(:capture2e)
      expect(PG).not_to have_received(:connect)
    end
  end
end
