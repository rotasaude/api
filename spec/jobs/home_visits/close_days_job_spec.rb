require "rails_helper"

# Módulo 24b (ADR 0052; contrato §2, §16; decisão 22; plano, Task 11): o job das
# 3h20 fecha toda folha aberta de dia anterior (dia da cidade), com o
# interruptor home_visits ligado ou não. Uma transação por folha; a que levanta
# não impede as outras e o job falha no fim com a contagem. Log só com contagens.
RSpec.describe HomeVisits::CloseDaysJob, type: :job do
  let!(:city) { home_visit_city! }
  let(:team) { registry_team! }
  let(:agent) { field_agent!(team: team) }
  let(:area) { registry_micro_area!(code: "01", team: team, acs: agent) }
  let(:today) { Time.zone.today }

  before { allow(Ledi::DeliverJob).to receive(:perform_later) }

  def sheet!(day, agent: self.agent)
    home_visit_day!(agent: agent, team: team, day: day).tap { |d| home_visit!(day: d, micro_area: area) }
  end

  def entries_of(day) = LediOutboxEntry.where(source_type: "HomeVisitDay", source_id: day.id)

  it "fecha a folha de ontem e deixa a de hoje" do
    yesterday = sheet!(today - 1)
    current = sheet!(today, agent: field_agent!(team: team))
    described_class.perform_now
    expect(yesterday.reload).to have_attributes(state: "closed", closed_by: "job", closed_by_user_id: nil)
    expect(current.reload.state).to eq("open")
    expect(entries_of(yesterday).count).to eq(1)
  end

  it "roda com home_visits desligado" do
    old = sheet!(today - 2)
    Platform::Features.set!(city: city, key: HomeVisits::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    described_class.perform_now
    expect(old.reload.state).to eq("closed")
  end

  it "rodar duas vezes fecha uma vez e gera uma ficha" do
    old = sheet!(today - 1)
    described_class.perform_now
    described_class.perform_now
    expect(entries_of(old).count).to eq(1)
    expect(DomainEvent.where(name: "home_visit_day.closed").count).to eq(1)
  end

  it "a folha que levanta não impede as outras e o job falha no fim com a contagem" do
    bad = sheet!(today - 1)
    good = sheet!(today - 1, agent: field_agent!(team: team))
    allow(HomeVisits::CloseDay).to receive(:call).and_wrap_original do |original, day, **opts|
      raise "boom" if day.id == bad.id
      original.call(day, **opts)
    end
    expect { described_class.perform_now }.to raise_error(EachCityJob::AggregatedFailure, /1 sheet\(s\) failed/)
    expect(good.reload.state).to eq("closed")
    expect(bad.reload.state).to eq("open")
  end

  it "o log não tem nome, motivo nem medida" do
    sheet!(today - 1)
    bad = sheet!(today - 1, agent: field_agent!(team: team))
    allow(HomeVisits::CloseDay).to receive(:call).and_wrap_original do |original, day, **opts|
      raise "segredo do paciente" if day.id == bad.id
      original.call(day, **opts)
    end
    log = capture_log { expect { described_class.perform_now }.to raise_error(StandardError) }
    expect(log).to include("[HomeVisits::CloseDaysJob] city=#{city.slug} closed=1 failed=1")
    expect(log).to include("sheet=#{bad.id}")
    expect(log).not_to include("segredo do paciente")
  end

  it "não atribui Current.city" do
    sheet!(today - 1)
    Current.reset
    described_class.perform_now
    expect(Current.city).to be_nil
  end

  it "está agendado todo dia às 3h20 no fuso de São Paulo, na fila housekeeping" do
    task = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/recurring.yml")).fetch("default").fetch("home_visits_close_days")
    expect(task).to include("class" => "HomeVisits::CloseDaysJob", "queue" => "housekeeping",
                            "schedule" => "every day at 3:20am America/Sao_Paulo")
  end
end
