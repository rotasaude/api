require "rails_helper"
require "rake"

# Guards I3: city:create mints database URLs with bootstrap superuser
# credentials (see CityProvisioner#database_url_for) — a role that can read
# every other city's database. Real provisioning is a later plan; until then
# this task must refuse to run outside development.
RSpec.describe "city:create rake task" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("city:create")
  end

  before do
    Rake::Task["city:create"].reenable
  end

  after { City.delete_all }

  it "aborts outside development" do
    allow(Rails.env).to receive(:development?).and_return(false)

    original_stderr, $stderr = $stderr, StringIO.new
    begin
      expect { Rake::Task["city:create"].invoke("naoroda#{SecureRandom.hex(3)}", "Nao Roda", "SP") }
        .to raise_error(SystemExit)
    ensure
      $stderr = original_stderr
    end

    expect(City.where("slug LIKE 'naoroda%'")).to be_empty
  end
end

# Guards I6 (code review, Task 4): the city schema dump uses force: :cascade,
# so a wrong target silently drops and recreates real tables. city:load_schema
# must refuse (a) any target whose database is the one behind primary/admin/
# queue/cache/platform/city_unset, in any environment declared in
# config/database.yml — not just the current one — and (b) running outside
# development/test, before it ever opens a connection to the target.
RSpec.describe "city:load_schema rake task" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("city:load_schema")
  end

  before do
    Rake::Task["city:load_schema"].reenable
  end

  def invoke_silently(*args)
    original_stderr, $stderr = $stderr, StringIO.new
    Rake::Task["city:load_schema"].invoke(*args)
  ensure
    $stderr = original_stderr
  end

  it "aborts outside development/test" do
    allow(Rails.env).to receive(:development?).and_return(false)
    allow(Rails.env).to receive(:test?).and_return(false)

    expect { invoke_silently("whatever-the-target-does-not-matter") }.to raise_error(SystemExit)
  end

  it "refuses a target that resolves to the shared database behind primary/admin (this environment)" do
    expect { invoke_silently("rota_saude_test") }.to raise_error(SystemExit)
  end

  it "refuses a target that resolves to a protected database from a DIFFERENT environment" do
    # rota_saude_development is primary/admin/queue/cache's database in
    # development, not in the test env this spec runs under — the guard must
    # still catch it, since it checks every environment's protected configs.
    expect { invoke_silently("rota_saude_development") }.to raise_error(SystemExit)
  end

  it "refuses a target that resolves to the platform or city_unset database" do
    expect { invoke_silently("rota_saude_platform_test") }.to raise_error(SystemExit)

    Rake::Task["city:load_schema"].reenable
    expect { invoke_silently("rota_saude_no_city_selected") }.to raise_error(SystemExit)
  end

  it "refuses a protected database given as a full postgres:// URL, not just a bare name" do
    url = "postgres://rota_saude:#{ENV.fetch('POSTGRES_PASSWORD', 'postgres')}@" \
          "#{ENV.fetch('DATABASE_HOST', '127.0.0.1')}:#{ENV.fetch('DATABASE_PORT', '5432')}/rota_saude_test"

    expect { invoke_silently(url) }.to raise_error(SystemExit)
  end

  # Regression (code review, round 2): the guard used to compare a bare-name
  # target's RAW STRING against the protected list, instead of resolving it
  # through the same postgres:// URL load_city_schema actually connects
  # with. A URL parser treats "?" as the start of a query string, "%XX" as
  # percent-encoding, and "#" as the start of a fragment — none of which
  # survive into the database name — so each of these bare-name inputs was
  # accepted by the old guard while still connecting to rota_saude_test.
  it "refuses a bare name that a URL parser would normalize down to a protected database" do
    ["rota_saude_test?sslmode=disable", "rota%5Fsaude_test", "rota_saude_test#x"].each do |bypass_attempt|
      Rake::Task["city:load_schema"].reenable
      expect { invoke_silently(bypass_attempt) }.to raise_error(SystemExit), "expected #{bypass_attempt.inspect} to be refused"
    end
  end

  it "accepts a legitimate city test database" do
    # city_b, not city_a: the suite's global around-hook
    # (spec/support/city_test_databases.rb) keeps a CityConnection pool open
    # to rota_saude_test_city_a for every single example, including this one.
    # Reloading city_b's schema here can't contend with that ambient
    # connection, and is otherwise the same idempotent force: :cascade reload
    # city:test_databases already does for both city test databases.
    expect { invoke_silently("rota_saude_test_city_b") }.not_to raise_error
  end
end

# city:dev_up cria banco e carrega schema com credencial de superusuário de
# bootstrap (CityProvisioner#database_url_for) — mesma razão de city:create para
# nunca rodar fora de development. Em test ela precisa abortar ANTES de tocar o
# catálogo.
RSpec.describe "city:dev_up and city:dev_baseline rake tasks" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("city:dev_up")
  end

  before do
    %w[city:dev_up city:dev_baseline].each { |name| Rake::Task[name].reenable }
  end

  def invoke_silently(name, *args)
    original_stderr, $stderr = $stderr, StringIO.new
    Rake::Task[name].invoke(*args)
  ensure
    $stderr = original_stderr
  end

  it "city:dev_up aborts outside development, before touching the catalog" do
    slug = "naosobe#{SecureRandom.hex(3)}"

    expect { invoke_silently("city:dev_up", slug, "Nao Sobe", "SP") }.to raise_error(SystemExit)
    expect(City.where(slug: slug)).to be_empty
  end

  it "city:dev_baseline aborts outside development, before touching the catalog" do
    expect { invoke_silently("city:dev_baseline") }.to raise_error(SystemExit)
    expect(City.where(slug: %w[curitiba maringa])).to be_empty
  end
end
