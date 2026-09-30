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

  # O primeiro run roda numa thread que SEGURA a própria conexão depois de
  # terminar (fica esperando dentro do CityConnection.with): se a trava de
  # sessão não fosse liberada, o run seguinte, em outra conexão, sairia nil.
  def first_run_holding_connection(&run)
    done = Queue.new
    threads << Thread.new do
      CityConnection.with(TEST_CITY_A) do
        outcome = begin
          run.call
        rescue StandardError => e
          e
        end
        done << [ outcome ]
        release.pop
      end
    end
    (done.pop(timeout: 10) or raise "o primeiro run não terminou").first
  end

  def second_run
    from, to = Analytics::Run.scheduled_window
    CityConnection.with(TEST_CITY_A) { Analytics::Run.call(kind: "rebuild", from: from, to: to) }
  end

  it "depois que o primeiro run termina, um novo run consegue a trava" do
    allow(Analytics::Publish).to receive(:call)
    from, to = Analytics::Run.scheduled_window
    first = first_run_holding_connection { Analytics::Run.call(kind: "scheduled", from: from, to: to) }
    expect(first.status).to eq("succeeded")

    expect(second_run&.status).to eq("succeeded")
  end

  it "run que falha libera a trava: o seguinte roda normalmente" do
    allow(Analytics::Publish).to receive(:call)
    from, to = Analytics::Run.scheduled_window
    allow(Analytics::Consolidate).to receive(:call).and_raise(RuntimeError, "boom")
    first = first_run_holding_connection { Analytics::Run.call(kind: "scheduled", from: from, to: to) }
    expect(first.status).to eq("failed")

    allow(Analytics::Consolidate).to receive(:call).and_call_original
    expect(second_run&.status).to eq("succeeded")
  end

  it "exceção que escapa do run libera a trava: o seguinte roda normalmente" do
    allow(Analytics::Publish).to receive(:call)
    from, to = Analytics::Run.scheduled_window
    allow(AnalyticsRun).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "PG::ConnectionBad")
    first = first_run_holding_connection { Analytics::Run.call(kind: "scheduled", from: from, to: to) }
    expect(first).to be_a(ActiveRecord::StatementInvalid)

    allow(AnalyticsRun).to receive(:create!).and_call_original
    expect(second_run&.status).to eq("succeeded")
  end
end
