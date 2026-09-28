require "rails_helper"

RSpec.describe "consent.revoked bindings (F-07.15)" do
  it "binds consent.revoked to the anonymize + record jobs" do
    consumers = DomainEvents.registry["consent.revoked"].map(&:job)
    expect(consumers).to include("AnonymizeRevokedTriageJob", "RecordConsentRevocationJob")
  end
end

# Módulo 04 (F-04.1, F-04.7; ADR 0004/0010): o relatório congelado e o link do
# cidadão saem de triage.completed. Sem o binding, nenhum snapshot nasce e
# nenhuma spec de job percebe (elas chamam o job direto).
RSpec.describe "triage.completed bindings (F-04.1, F-04.7)" do
  it "binds triage.completed to GenerateReportJob and NotifyCitizenJob" do
    consumers = DomainEvents.registry["triage.completed"].map(&:job)
    expect(consumers).to include("GenerateReportJob", "NotifyCitizenJob")
  end

  it "enqueues both consumers when the event is published" do
    Current.city = TEST_CITY_A
    event_id = DomainEvents.publish("triage.completed", triage_id: SecureRandom.uuid, tier: "alta")
    enqueued = ActiveJob::Base.queue_adapter.enqueued_jobs
                              .select { |job| job.dig("arguments", 0, "event_id") == event_id }
                              .map { |job| job["job_class"] }

    expect(enqueued).to include("GenerateReportJob", "NotifyCitizenJob")
  ensure
    Current.reset
  end
end

# Módulo 11 (ADR 0023): eventos do território declarados, só trilha.
RSpec.describe "territory event bindings (ADR 0023)" do
  it "declares every territory event with no consumer" do
    names = %w[neighborhood.created neighborhood.renamed neighborhood.deactivated neighborhood.activated
               neighborhood.coverage_changed citizen.neighborhood_changed]
    expect(DomainEvents.registry.keys).to include(*names)
    expect(names.flat_map { |n| DomainEvents.registry[n] }).to be_empty
  end
end
