require "rails_helper"

# Banco e role por cidade (spec banco-por-cidade §4, Plano 4). Cria bancos e roles
# DE VERDADE com rota_provisioner — sem transação de fixture — e apaga tudo no
# `after`. Slugs sempre com prefixo "prov".
RSpec.describe CityDatabase do
  self.use_transactional_tests = false

  let(:slug_a) { "prov#{SecureRandom.hex(4)}" }
  let(:slug_b) { "prov#{SecureRandom.hex(4)}" }
  let(:pwd_a) { SecureRandom.hex(24) }
  let(:pwd_b) { SecureRandom.hex(24) }

  # The last example below stubs Rails.env.production? for its own assertion;
  # RSpec mocks teardown runs after every after-hook, so the stub is still
  # active here for that example. Nothing was ever provisioned under it (that
  # example never calls ensure!), so ProvisionerMissing there means "nothing to
  # clean up," not a real cleanup failure.
  after do
    [ slug_a, slug_b ].each do |slug|
      described_class.drop!(slug: slug)
    rescue CityDatabase::ProvisionerMissing
    end
  end

  def superuser_value(sql, *params)
    ScratchDatabases.superuser { |conn| conn.exec_params(sql, params).getvalue(0, 0) }
  end

  it "names databases and roles per environment and refuses slugs that are unsafe as identifiers" do
    expect(described_class.database_name("curitiba")).to eq("rota_saude_test_city_curitiba")
    expect(described_class.role_name("curitiba")).to eq("rota_test_city_curitiba")

    [ "a", "x" * 41, "Maiuscula", "com espaco", "-hifen", "admin", %w[lista], nil ].each do |bad|
      expect { described_class.database_name(bad) }.to raise_error(CityDatabase::InvalidSlug)
      expect(described_class.valid_slug?(bad)).to be(false)
    end
    expect(described_class.valid_slug?("x" * 40)).to be(true)
  end

  it "builds the city URL with the city's own role on DATABASE_HOST/DATABASE_PORT outside production, sslmode only when set" do
    allow(described_class).to receive(:provisioner_url).and_call_original
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CITY_DATABASE_HOST").and_return(nil)
    allow(ENV).to receive(:[]).with("CITY_DATABASE_PORT").and_return(nil)
    allow(ENV).to receive(:[]).with("CITY_DATABASE_SSLMODE").and_return(nil)

    url = URI.parse(described_class.url_for(slug: "curitiba", password: "abc123"))

    expect([ url.scheme, url.user, url.password, url.host, url.port, url.path, url.query ])
      .to eq([ "postgres", "rota_test_city_curitiba", "abc123", ENV.fetch("DATABASE_HOST", "127.0.0.1"),
               ENV.fetch("DATABASE_PORT", "5432").to_i, "/rota_saude_test_city_curitiba", nil ])

    allow(ENV).to receive(:[]).with("CITY_DATABASE_SSLMODE").and_return("verify-full")
    expect(URI.parse(described_class.url_for(slug: "curitiba", password: "abc123")).query).to eq("sslmode=verify-full")
    # Checked here, not as a message expectation: the `after` drop hook does use it.
    expect(described_class).not_to have_received(:provisioner_url)
  end

  it "creates a role that owns its database, with CONNECT revoked from PUBLIC, idempotently" do
    2.times { described_class.ensure!(slug: slug_a, password: pwd_a) }

    database = described_class.database_name(slug_a)
    expect(described_class.exists?(slug: slug_a)).to be(true)
    expect(superuser_value("SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = $1", database))
      .to eq(described_class.role_name(slug_a))
    expect(superuser_value("SELECT datacl::text FROM pg_database WHERE datname = $1", database)).not_to match(/[{,]=/)
    expect(superuser_value("SELECT rolpassword FROM pg_authid WHERE rolname = $1", described_class.role_name(slug_a)))
      .to start_with("SCRAM-SHA-256$")
    PG.connect(described_class.url_for(slug: slug_a, password: pwd_a)).close
  end

  it "keeps a city's role out of another city's database, and rota_app out of both" do
    described_class.ensure!(slug: slug_a, password: pwd_a)
    described_class.ensure!(slug: slug_b, password: pwd_b)

    cross = described_class.url_for(slug: slug_a, password: pwd_a)
                           .sub("/#{described_class.database_name(slug_a)}", "/#{described_class.database_name(slug_b)}")
    expect { PG.connect(cross) }.to raise_error(PG::ConnectionBad, /permission denied/)

    rota_app = CityDatabaseUrls.city_database_url(described_class.database_name(slug_a),
                                                  user: "rota_app", password: ENV.fetch("ROTA_APP_PASSWORD", "rota_app"))
    expect { PG.connect(rota_app) }.to raise_error(PG::ConnectionBad, /permission denied/)
  end

  it "realigns the role password with the catalog when run again" do
    role = described_class.role_name(slug_a)
    described_class.ensure!(slug: slug_a, password: "antiga#{pwd_a}")
    before = superuser_value("SELECT rolpassword FROM pg_authid WHERE rolname = $1", role)

    described_class.ensure!(slug: slug_a, password: pwd_a)

    expect(superuser_value("SELECT rolpassword FROM pg_authid WHERE rolname = $1", role)).not_to eq(before)
    PG.connect(described_class.url_for(slug: slug_a, password: pwd_a)).close
  end

  it "caps how many connections a city's role can open" do
    described_class.ensure!(slug: slug_a, password: pwd_a)

    limit = superuser_value("SELECT rolconnlimit FROM pg_roles WHERE rolname = $1", described_class.role_name(slug_a))

    expect(limit.to_i).to eq(described_class.role_connection_limit)
  end

  # ensure! é idempotente e realinha a senha; o teto tem de seguir a mesma
  # regra, senão um role criado antes deste plano ficaria sem limite para
  # sempre.
  it "re-applies the cap when the role already exists without one" do
    described_class.ensure!(slug: slug_a, password: pwd_a)
    ScratchDatabases.superuser do |conn|
      conn.exec("ALTER ROLE #{PG::Connection.quote_ident(described_class.role_name(slug_a))} CONNECTION LIMIT -1")
    end

    described_class.ensure!(slug: slug_a, password: pwd_a)

    limit = superuser_value("SELECT rolconnlimit FROM pg_roles WHERE rolname = $1", described_class.role_name(slug_a))
    expect(limit.to_i).to eq(described_class.role_connection_limit)
  end

  it "defaults the role connection limit to 100 when CITY_ROLE_CONNECTION_LIMIT is absent" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CITY_ROLE_CONNECTION_LIMIT").and_return(nil)

    expect(described_class.role_connection_limit).to eq(100)
  end

  # Fix round 1 (review): confirma que um override válido chega de fato à
  # role no Postgres, não só ao método que lê o ENV.
  it "applies a valid CITY_ROLE_CONNECTION_LIMIT override to the role's CONNECTION LIMIT" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CITY_ROLE_CONNECTION_LIMIT").and_return("42")

    expect(described_class.role_connection_limit).to eq(42)

    described_class.ensure!(slug: slug_a, password: pwd_a)

    limit = superuser_value("SELECT rolconnlimit FROM pg_roles WHERE rolname = $1", described_class.role_name(slug_a))
    expect(limit.to_i).to eq(42)
  end

  # Fix round 1 (review): um `.to_i` ingênuo transformava "" em 0, e
  # CONNECTION LIMIT 0 no Postgres não é "sem limite" — é "nenhuma conexão",
  # trancando a própria cidade fora do banco dela no próximo ensure!. "" está
  # aqui explicitamente porque foi essa forma que produziu o lock-out real.
  it "rejects a CITY_ROLE_CONNECTION_LIMIT that is not a positive integer, naming the variable but not echoing the value" do
    [ "", "  ", "abc", "0", "-5", "1e2", "3.5" ].each do |bad|
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("CITY_ROLE_CONNECTION_LIMIT").and_return(bad)

      expect { described_class.role_connection_limit }.to raise_error(CityDatabase::ConfigMissing) do |error|
        expect(error.message).to include("CITY_ROLE_CONNECTION_LIMIT")
      end
    end
  end

  it "drops database and role, and dropping again is a no-op" do
    described_class.ensure!(slug: slug_a, password: pwd_a)

    2.times { described_class.drop!(slug: slug_a) }

    expect(described_class.exists?(slug: slug_a)).to be(false)
    expect(superuser_value("SELECT count(*) FROM pg_roles WHERE rolname = $1", described_class.role_name(slug_a))).to eq("0")
  end

  it "drops a database and role that never existed without error (idempotent on a nonexistent DB)" do
    expect { described_class.drop!(slug: slug_a) }.not_to raise_error

    expect(described_class.exists?(slug: slug_a)).to be(false)
  end

  it "terminates an open client session on the city database so drop! succeeds on the first attempt, with no retry" do
    described_class.ensure!(slug: slug_a, password: pwd_a)
    held = PG.connect(described_class.url_for(slug: slug_a, password: pwd_a))
    held.exec("SELECT 1")

    drop_statements = []
    allow_any_instance_of(PG::Connection).to receive(:exec).and_wrap_original do |original, sql|
      drop_statements << sql if sql.include?("DROP DATABASE")
      original.call(sql)
    end

    begin
      described_class.drop!(slug: slug_a)

      expect(drop_statements.size).to eq(1) # no retry loop: exactly one DROP DATABASE statement
      expect(described_class.exists?(slug: slug_a)).to be(false)
      expect { held.exec("SELECT 1") }.to raise_error(PG::Error)

      # M3 (hardening review, Task 3): not just "the DB is gone" — assert no
      # client backend for it survives either, via a fresh superuser session
      # (the city's own database no longer exists, so query pg_stat_activity
      # from the platform/bootstrap connection instead).
      remaining = superuser_value(
        "SELECT count(*) FROM pg_stat_activity WHERE datname = $1 AND backend_type = 'client backend'",
        described_class.database_name(slug_a)
      )
      expect(remaining).to eq("0")
    ensure
      held.close
    end
  end

  it "never issues FORCE when dropping" do
    described_class.ensure!(slug: slug_a, password: pwd_a)

    statements = []
    allow_any_instance_of(PG::Connection).to receive(:exec).and_wrap_original do |original, sql|
      statements << sql
      original.call(sql)
    end

    described_class.drop!(slug: slug_a)

    # M2 (hardening review, Task 3): a spy on an empty list of statements
    # would also pass the FORCE assertion below — assert the spy actually
    # captured the drop sequence's real statements first.
    expect(statements).to include(a_string_matching(/\AALTER DATABASE/))
    expect(statements).to include(a_string_matching(/\ADROP DATABASE/))
    expect(statements.grep(/FORCE/i)).to be_empty
  end

  # I1 (hardening review, Task 3): the DropBlocked path — a session
  # rota_provisioner cannot terminate (here, a real Postgres superuser
  # session held on the city database) — must fail with a count-only
  # message (no pid, no username), and a second drop! must still succeed
  # once that session is gone, on a database left with ALLOW_CONNECTIONS
  # false by the first (blocked) attempt.
  it "raises DropBlocked with a count-only message when a session it cannot terminate is open, then succeeds on retry" do
    described_class.ensure!(slug: slug_a, password: pwd_a)
    database = described_class.database_name(slug_a)
    held = PG.connect(CityDatabaseUrls.city_database_url(database)) # rota_saude: real Postgres superuser
    held.exec("SELECT 1")

    begin
      expect { described_class.drop!(slug: slug_a) }.to raise_error(CityDatabase::DropBlocked) do |error|
        # Count-only shape: "N sessão(ões) bloqueando o drop de <database>" —
        # no pid, no usename column value anywhere in the message (the
        # database name legitimately contains "rota_saude" as a substring,
        # so this checks for the connected user's pid, not a loose substring
        # match against the role name).
        expect(error.message).to match(/\A1 sessão\(ões\) bloqueando o drop de #{Regexp.escape(database)}\z/)
        expect(error.message).not_to match(/\bpid\b/i)
        expect(error.message).not_to include(held.exec("SELECT pg_backend_pid()").getvalue(0, 0))
      end

      expect(described_class.exists?(slug: slug_a)).to be(true)
      expect(superuser_value("SELECT datallowconn FROM pg_database WHERE datname = $1", database)).to eq("f")
    ensure
      held.close
    end

    described_class.drop!(slug: slug_a)

    expect(described_class.exists?(slug: slug_a)).to be(false)
    expect(superuser_value("SELECT count(*) FROM pg_roles WHERE rolname = $1", described_class.role_name(slug_a))).to eq("0")
  end

  it "requires PROVISIONER_DATABASE_URL in production" do
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("PROVISIONER_DATABASE_URL").and_return(nil)

    expect { described_class.provisioner_url }.to raise_error(CityDatabase::ProvisionerMissing)
  end
end

# The web process builds the city URL in production without the worker-only
# provisioner secret. Its own describe, with no drop hook: the Rails.env stubs
# are still active in `after` hooks.
RSpec.describe CityDatabase, ".url_for in production" do
  before do
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(Rails.env).to receive(:test?).and_return(false)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("PROVISIONER_DATABASE_URL").and_return(nil)
    allow(ENV).to receive(:[]).with("CITY_DATABASE_PORT").and_return(nil)
    allow(ENV).to receive(:[]).with("CITY_DATABASE_SSLMODE").and_return(nil)
  end

  it "uses CITY_DATABASE_HOST, port 5432 and sslmode=require, never the provisioner URL" do
    allow(ENV).to receive(:[]).with("CITY_DATABASE_HOST").and_return("db.example")

    expect(described_class.url_for(slug: "curitiba", password: "abc123"))
      .to eq("postgres://rota_city_curitiba:abc123@db.example:5432/rota_saude_city_curitiba?sslmode=require")
  end

  it "requires CITY_DATABASE_HOST" do
    allow(ENV).to receive(:[]).with("CITY_DATABASE_HOST").and_return("")

    expect { described_class.url_for(slug: "curitiba", password: "abc123") }
      .to raise_error(CityDatabase::ConfigMissing, "CITY_DATABASE_HOST ausente")
  end
end
