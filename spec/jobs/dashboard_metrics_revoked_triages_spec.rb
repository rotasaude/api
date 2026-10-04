require "rails_helper"

# api#34: dashboard_metrics deixa a triagem revogada fora das dimensões de
# concluídas, nos dois caminhos (ADR 0010): a reconstrução noturna (F-05.14)
# e o contínuo (F-05.13), que precisa convergir com ela depois da revogação.
RSpec.describe "dashboard_metrics sem triagem revogada (api#34)", type: :job do
  # Mesmo slug/banco de TEST_CITY_A: o with_city do IdempotentConsumer reentra o
  # shard que o harness já abriu.
  let!(:city) do
    create(:city, slug: TEST_CITY_A.slug, status: "active", database_url: city_database_url("rota_saude_test_city_a"))
  end

  let(:day) { Date.new(2026, 9, 10) }
  let(:date) { day.iso8601 }
  let(:unit) { create_unit("UBS Centro") }
  let(:dimensions) { %w[triages_by_tier triages_total priority_distribution] }

  def event_args(name, payload)
    { event_id: SecureRandom.uuid, event_name: name, city_slug: city.slug, payload: payload.stringify_keys }
  end

  def rebuild!(**kwargs)
    RebuildDashboardMetricsJob.instance_method(:perform).super_method.bind_call(RebuildDashboardMetricsJob.new, **kwargs)
  end

  def triage_rows
    DashboardMetric.where(dimension: dimensions).order(:dimension, :period, :key).pluck(:dimension, :period, :key, :value)
  end

  def complete!(**opts)
    a_triage!(day: day, **opts).tap do |t|
      UpdateDashboardJob.new.perform(**event_args("triage.completed", triage_id: t.id))
    end
  end

  # Revoga como o wpda: depois de concluir, pelo comando (o evento sai dele).
  def revoke!(triage)
    RevokeConsent.call(conversation: triage.conversation, origin: "web")
  end

  def consumers_of_revocation(triage, order:)
    args = event_args("consent.revoked", conversation_id: triage.conversation_id)
    order.each { |job| job.new.perform(**args) }
  end

  describe RebuildDashboardMetricsJob do
    it "não conta revogada (com ou sem atendimento, nem abortada por revogação) em tier, total e prioridade" do
      a_triage!(day: day, tier: "alta", priority: 1)
      an_attendance!(triage: a_triage!(day: day, hour: 11, tier: "alta", priority: 1, revoked: true), unit: unit)
      a_triage!(day: day, hour: 12, tier: "baixa", priority: 9, revoked: true)
      a_triage!(day: day, hour: 13, status: "aborted_by_revocation")

      rebuild!

      expect(triage_rows).to eq([
        [ "priority_distribution", date, "1",     1 ],
        [ "triages_by_tier",       date, "alta",  1 ],
        [ "triages_total",         date, "total", 1 ]
      ])
    end
  end

  describe "convergência do contínuo depois da revogação" do
    before do
      complete!(tier: "alta", priority: 1)
      complete!(hour: 11, tier: "baixa", priority: 9)
    end

    it "sem atendimento, com o anonimizador rodando ANTES: o contínuo fica igual ao rebuild do dia" do
      target = complete!(hour: 12, tier: "alta", priority: 1)
      revoke!(target)
      consumers_of_revocation(target, order: [ AnonymizeRevokedTriageJob, RecordConsentRevocationJob,
                                               ForgetRevokedTriageMetricsJob ])
      live = triage_rows

      rebuild!(since: date)

      expect(live).to eq(triage_rows)
      expect(live).to include([ "triages_by_tier", date, "alta", 1 ], [ "triages_total", date, "total", 2 ])
    end

    it "com atendimento, com o anonimizador rodando DEPOIS: o contínuo fica igual ao rebuild do dia" do
      target = complete!(hour: 12, tier: "alta", priority: 1)
      an_attendance!(triage: target, unit: unit)
      revoke!(target)
      consumers_of_revocation(target, order: [ ForgetRevokedTriageMetricsJob, RecordConsentRevocationJob,
                                               AnonymizeRevokedTriageJob ])
      live = triage_rows

      rebuild!(since: date)

      expect(live).to eq(triage_rows)
      expect(live).to include([ "triages_by_tier", date, "alta", 1 ], [ "triages_total", date, "total", 2 ])
    end

    it "conclusão entregue depois da revogação não volta a somar a revogada" do
      target = a_triage!(day: day, hour: 12, tier: "alta", priority: 1)
      an_attendance!(triage: target, unit: unit)
      revoke!(target)
      consumers_of_revocation(target, order: [ ForgetRevokedTriageMetricsJob ])
      UpdateDashboardJob.new.perform(**event_args("triage.completed", triage_id: target.id))
      live = triage_rows

      rebuild!(since: date)

      expect(live).to eq(triage_rows)
    end
  end

  describe "DashboardMetric.recompute_triage_day! sob bump concorrente" do
    it "fica com o valor da fonte mesmo se outro job grava a mesma chave entre o delete e o insert" do
      2.times { |i| a_triage!(day: day, hour: 10 + i, tier: "alta", priority: 1) }
      allow(DashboardMetric).to receive(:triage_counts).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs).tap do
          # Simula o UpdateDashboardJob (ou o rebuild) de outra thread da fila :reports.
          DashboardMetric.bump!(dimension: "triages_by_tier", period: date, key: "alta")
          DashboardMetric.bump!(dimension: "triages_total", period: date, key: "total")
        end
      end

      expect { DashboardMetric.recompute_triage_day!(date) }.not_to raise_error
      expect(triage_rows).to eq([
        [ "priority_distribution", date, "1",     2 ],
        [ "triages_by_tier",       date, "alta",  2 ],
        [ "triages_total",         date, "total", 2 ]
      ])
    end
  end

  it "consent.revoked também liga o ForgetRevokedTriageMetricsJob" do
    expect(DomainEvents.registry["consent.revoked"].map(&:job)).to include("ForgetRevokedTriageMetricsJob")
  end
end
