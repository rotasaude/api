require "rails_helper"

# Spec §4.1 e §10.1 (job): janela, idempotência, atraso dentro e fora da
# janela, falha num consolidador, dia corrente, publicação e purgas.
RSpec.describe Analytics::Run do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city_record) { register_test_city! }
  let(:today) { Time.zone.today }
  let(:unit) { create_unit("UBS Centro") }
  let!(:protocol) { create_default_protocol! }

  def snapshot = AnalyticsDailyFact.order(:day, :metric, :dim, :tier, :neighborhood_id, :health_unit_id)
                                   .pluck(:day, :metric, :health_unit_id, :neighborhood_id, :protocol_name,
                                          :protocol_version, :tier, :question_id, :dim, :value)

  it "a janela agendada vai de hoje − 30 a ontem" do
    expect(described_class.scheduled_window(today)).to eq([ today - 30, today - 1 ])
  end

  it "grava o run, consolida, publica e marca succeeded" do
    a_triage!(day: today - 2)

    run = scheduled_run!

    expect(run.reload).to have_attributes(kind: "scheduled", status: "succeeded", window_from: today - 30,
                                          window_to: today - 1, error: nil)
    expect(run.finished_at).to be_present
    expect(run.published_at).to be_present
    expect(AnalyticsDailyFact.where(metric: "triage.started", day: today - 2).sum(:value)).to eq(1)
    expect(CityAnalyticsIndicator.where(city_id: city_record.id)).to exist
  end

  it "duas execuções produzem os mesmos fatos" do
    an_attendance!(triage: a_triage!(day: today - 4), unit: unit, wait_minutes: 40, outcome: "return")
    a_triage!(day: today - 9, status: "aborted_by_timeout")

    scheduled_run!
    first = snapshot
    scheduled_run!

    expect(snapshot).to eq(first)
    expect(AnalyticsRun.pluck(:status)).to eq(%w[succeeded succeeded])
  end

  it "desfecho atrasado dentro da janela entra; fora da janela, não" do
    inside = a_triage!(day: today - 10, tier: "alta")
    outside = a_triage!(day: today - 40, tier: "alta")
    described_class.call(kind: "rebuild", from: today - 40, to: today - 31)
    scheduled_run!
    [ inside, outside ].each { |t| an_attendance!(triage: t, unit: unit, checked_in_at: Time.current - 2.hours) }

    scheduled_run!

    dims = ->(day) { AnalyticsDailyFact.where(metric: "calibration.outcome", day: day).pluck(:dim) }
    expect(dims.call(today - 10)).to eq(%w[discharged])
    expect(dims.call(today - 40)).to eq(%w[none])
  end

  it "falha num consolidador: run failed, rollback, fatos anteriores intactos" do
    a_triage!(day: today - 3)
    scheduled_run!
    before = snapshot
    a_triage!(day: today - 3)
    allow(Analytics::Consolidate::Quality).to receive(:call).and_raise(RuntimeError, "boom\nDETAIL: linha 42")

    run = scheduled_run!

    expect(run.reload).to have_attributes(status: "failed", error: "RuntimeError: boom", published_at: nil)
    expect(snapshot).to eq(before)
  end

  it "nunca consolida o dia corrente nem janela invertida" do
    expect { described_class.call(kind: "rebuild", from: today - 3, to: today) }.to raise_error(ArgumentError)
    expect { described_class.call(kind: "rebuild", from: today - 1, to: today - 2) }.to raise_error(ArgumentError)
    expect(AnalyticsRun.count).to eq(0)
  end

  it "com outra consolidação em curso, sai sem gravar nada" do
    allow(described_class).to receive(:try_lock).and_return(false)

    expect(scheduled_run!).to be_nil
    expect(AnalyticsRun.count).to eq(0)
  end

  it "falha da plataforma não derruba o run: succeeded, sem published_at, com o erro" do
    a_triage!(day: today - 2)
    allow(Analytics::Publish).to receive(:call).and_raise(ActiveRecord::ConnectionNotEstablished, "plataforma fora")

    run = scheduled_run!

    expect(run.reload).to have_attributes(status: "succeeded", published_at: nil,
                                          error: "publish: ActiveRecord::ConnectionNotEstablished: plataforma fora")
    expect(AnalyticsDailyFact.where(day: today - 2)).to exist
  end

  it "consolidação com erro de unicidade: nunca expõe CPF nem DETAIL do PostgreSQL" do
    a_triage!(day: today - 3)
    message = "ERROR:  duplicate key value violates unique constraint \"index_citizens_on_cpf\"\nDETAIL:  Key (cpf)=(123.456.789-09) already exists."
    allow(Analytics::Consolidate::Quality).to receive(:call).and_raise(ActiveRecord::RecordNotUnique, message)

    run = scheduled_run!

    expect(run.reload).to have_attributes(status: "failed")
    expect(run.error).to match(/^ActiveRecord::RecordNotUnique: ERROR:.*index_citizens_on_cpf/)
    expect(run.error).not_to include("123.456.789-09")
    expect(run.error).not_to include("DETAIL")
  end

  it "falha de publicação com erro de unicidade: error começa com 'publish:' e exclui CPF" do
    a_triage!(day: today - 2)
    message = "ERROR:  duplicate key value violates unique constraint \"some_idx\"\nDETAIL:  Key (cpf)=(999.999.999-99) already exists."
    allow(Analytics::Publish).to receive(:call).and_raise(ActiveRecord::RecordNotUnique, message)

    run = scheduled_run!

    expect(run.reload).to have_attributes(status: "succeeded")
    expect(run.error).to start_with("publish: ActiveRecord::RecordNotUnique: ERROR:")
    expect(run.error).not_to include("999.999.999-99")
    expect(run.error).not_to include("DETAIL")
  end

  it "erro com primeira linha maior que 500 chars: armazenado truncado" do
    a_triage!(day: today - 3)
    long_first_line = "x" * 600 + "\nDETAIL: secret"
    allow(Analytics::Consolidate::Quality).to receive(:call).and_raise(RuntimeError, long_first_line)

    run = scheduled_run!

    expect(run.reload).to have_attributes(status: "failed")
    expect(run.error.length).to be <= 500
    expect(run.error).not_to include("DETAIL")
  end

  it "purga fatos com mais de 5 anos e runs com mais de 90 dias, guardando o último succeeded" do
    old = fact!(metric: "triage.started", day: today - 5.years - 1, value: 9)
    edge = fact!(metric: "triage.started", day: today - 5.years, value: 9)
    kept_run = consolidated_run!(finished_at: 100.days.ago)
    old_failed = AnalyticsRun.create!(kind: "scheduled", status: "failed", window_from: today - 130, window_to: today - 101,
                                      started_at: 95.days.ago, finished_at: 95.days.ago, error: "RuntimeError: x")
    allow(Analytics::Consolidate).to receive(:call).and_raise("boom") # nenhum succeeded novo

    scheduled_run!
    expect(AnalyticsRun.exists?(kept_run.id)).to be(true) # o run failed não purga

    allow(Analytics::Consolidate).to receive(:call).and_call_original
    scheduled_run!

    expect(AnalyticsDailyFact.exists?(old.id)).to be(false)
    expect(AnalyticsDailyFact.exists?(edge.id)).to be(true)
    expect(AnalyticsRun.exists?(old_failed.id)).to be(false)
    expect(AnalyticsRun.exists?(kept_run.id)).to be(false) # já há um succeeded mais novo
  end

  # Borda da purga (spec §3.2: "mais de 90 dias"): started_at < agora − 90 d.
  # Exatamente 90 dias fica; 1 s a mais já sai.
  it "purga de runs na borda exata de 90 dias" do
    freeze_time do
      ages = { "89d" => 89.days, "90d" => 90.days, "90d+1s" => 90.days + 1.second, "91d" => 91.days }
      runs = ages.transform_values do |age|
        AnalyticsRun.create!(kind: "scheduled", status: "failed", window_from: today - 130, window_to: today - 101,
                             started_at: Time.current - age, finished_at: Time.current - age, error: "RuntimeError: x")
      end

      scheduled_run!

      expect(ages.keys.select { |key| AnalyticsRun.exists?(runs[key].id) }).to eq(%w[89d 90d])
    end
  end
end
