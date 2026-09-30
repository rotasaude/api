require "rails_helper"

# Spec §4.1/§10.1: advisory lock por cidade — dois runs concorrentes, um só
# roda. Só threads reais contra o banco real de TEST_CITY_A (sem fixture
# transacional) exercitam o lock de sessão do Postgres; mesmo padrão de
# spec/models/health_unit_lock_spec.rb.
RSpec.describe "Analytics::Run: uma consolidação por cidade" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }

  # Os writes commitam de verdade: solta e encerra as threads mesmo com a
  # expectativa falhando no meio, e só então apaga o que o run gravou.
  after do
    2.times { release << true }
    threads.each { |t| t.join(5) || t.kill }
    CityConnection.with(TEST_CITY_A) do
      AnalyticsDailyFact.delete_all
      AnalyticsRun.delete_all
    end
  end

  it "o segundo run concorrente sai sem gravar analytics_runs" do
    allow(Analytics::Publish).to receive(:call)
    inside = Queue.new
    allow(Analytics::Consolidate).to receive(:call).and_wrap_original do |original, **kwargs|
      inside << true
      release.pop
      original.call(**kwargs)
    end
    from, to = Analytics::Run.scheduled_window

    threads << Thread.new do
      CityConnection.with(TEST_CITY_A) { Analytics::Run.call(kind: "scheduled", from: from, to: to) }
    end
    inside.pop(timeout: 5) or raise "o primeiro run não entrou na consolidação"

    second = CityConnection.with(TEST_CITY_A) { Analytics::Run.call(kind: "rebuild", from: from, to: to) }

    expect(second).to be_nil
    release << true
    threads.each { |t| t.join(10) }
    expect(CityConnection.with(TEST_CITY_A) { AnalyticsRun.pluck(:kind, :status) }).to eq([ %w[scheduled succeeded] ])
  end
end
