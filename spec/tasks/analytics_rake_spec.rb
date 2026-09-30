# spec/tasks/analytics_rake_spec.rb
require "rails_helper"
require "rake"

RSpec.describe "city:analytics:rebuild rake task" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("city:analytics:rebuild")
  end

  before do
    Rake::Task["city:analytics:rebuild"].reenable
    Rake::Task["city:analytics:rebuild:all"].reenable
    create_default_protocol!
  end

  after { CityCatalog.reset_cache! }

  # A mesma linha de catálogo que os request specs usam: CityConnection.with(city)
  # cai na conexão de TEST_CITY_A da transação.
  let!(:city) { register_test_city! }

  def run(task, *args)
    out = StringIO.new
    original_stdout, $stdout = $stdout, out
    original_stderr, $stderr = $stderr, (@err = StringIO.new)
    Rake::Task[task].invoke(*args)
    out.string
  ensure
    $stdout = original_stdout
    $stderr = original_stderr
  end

  def err = @err.string

  it "reconsolida a cidade do cru mais antigo até ontem e relata os blocos" do
    a_triage!(day: Time.zone.today - 40)

    expect(run("city:analytics:rebuild", city.slug)).to include("#{city.slug}: 2 blocos de #{Time.zone.today - 40}")
    expect(AnalyticsRun.where(kind: "rebuild").count).to eq(2)
  end

  it "aceita from e to" do
    from = (Time.zone.today - 10).iso8601
    to = (Time.zone.today - 3).iso8601
    expect(run("city:analytics:rebuild", city.slug, from, to)).to include("1 blocos de #{from} a #{to}")
  end

  it "cidade sem cru: mensagem e saída sem erro" do
    expect(run("city:analytics:rebuild", city.slug)).to include("sem dado cru a consolidar")
  end

  it "slug ausente, cidade inexistente ou data inválida: aborta" do
    expect { run("city:analytics:rebuild") }.to raise_error(SystemExit)
    Rake::Task["city:analytics:rebuild"].reenable
    expect { run("city:analytics:rebuild", "nao-existe") }.to raise_error(SystemExit)
    Rake::Task["city:analytics:rebuild"].reenable
    expect { run("city:analytics:rebuild", city.slug, "2026-02-30") }.to raise_error(SystemExit)
  end

  it ":all passa por toda cidade ativa e aborta se alguma falhar" do
    a_triage!(day: Time.zone.today - 3)
    allow(Analytics::Consolidate).to receive(:call).and_raise(RuntimeError, "boom")

    expect { run("city:analytics:rebuild:all") }.to raise_error(SystemExit)
    expect(AnalyticsRun.where(status: "failed")).to exist
  end

  it ":all caminho de sucesso: reconsolida a cidade ativa e relata os blocos" do
    a_triage!(day: Time.zone.today - 3)

    expect(run("city:analytics:rebuild:all")).to include("#{city.slug}: 1 blocos de #{Time.zone.today - 3}")
    expect(AnalyticsRun.where(kind: "rebuild").pluck(:status)).to eq(%w[succeeded])
  end

  it ":all pula cidade que não está active" do
    suspended = create(:city, status: "suspended")
    # Sem o atalho do schema: a cidade suspensa não pode ser pulada por ele.
    allow(CitySchema).to receive(:behind?).and_return(false)
    allow(CityConnection).to receive(:with).and_call_original

    expect { run("city:analytics:rebuild:all") }.not_to raise_error

    expect(CityConnection).not_to have_received(:with).with(have_attributes(id: suspended.id))
    expect(CityConnection).to have_received(:with).with(have_attributes(id: city.id))
  end

  it "schema atrasado: a cidade aborta com a mensagem, sem consolidar" do
    allow(CitySchema).to receive(:behind?).and_return(true)

    expect { run("city:analytics:rebuild", city.slug) }
      .to raise_error(SystemExit, "[city:analytics:rebuild] #{city.slug} com schema atrasado — rode city:migrate:all")
    Rake::Task["city:analytics:rebuild:all"].reenable
    expect { run("city:analytics:rebuild:all") }.to raise_error(SystemExit, /falharam: #{city.slug}/)
    expect(err).to include("#{city.slug} falhou — RuntimeError: schema atrasado — rode city:migrate:all")
    expect(AnalyticsRun.count).to eq(0)
  end

  it "outra consolidação em curso: aborta pedindo para tentar de novo" do
    a_triage!(day: Time.zone.today - 3)
    allow(Analytics::Run).to receive(:try_lock).and_return(false)

    expect { run("city:analytics:rebuild", city.slug) }
      .to raise_error(SystemExit, "[city:analytics:rebuild] #{city.slug}: outra consolidação em curso — tente de novo")
    Rake::Task["city:analytics:rebuild:all"].reenable
    expect { run("city:analytics:rebuild:all") }.to raise_error(SystemExit, /falharam: #{city.slug}/)
    expect(err).to include("outra consolidação em curso")
    expect(AnalyticsRun.count).to eq(0)
  end
end
