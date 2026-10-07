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

# Módulo 12 (ADR 0024): eventos das campanhas declarados, só trilha.
RSpec.describe "campaign event bindings (ADR 0024)" do
  it "declares every campaign event with no consumer" do
    names = %w[campaign.created campaign.scheduled campaign.unscheduled campaign.cancelled campaign.dispatched
               campaign.failed campaign.sms_unavailable citizen.contact_preferences_changed
               city.campaigns_sms_toggled]
    expect(DomainEvents.registry.keys).to include(*names)
    expect(names.flat_map { |n| DomainEvents.registry[n] }).to be_empty
  end
end

# Módulo 15 (ADR 0027): eventos do catálogo de triagens, só ids e sem consumidor.
RSpec.describe "triage catalog event bindings (ADR 0027)" do
  it "declares every triage catalog event with no consumer" do
    names = %w[citizen.profile_changed triage.suggested triage_offer.changed]
    expect(DomainEvents.registry.keys).to include(*names)
    expect(names.flat_map { |n| DomainEvents.registry[n] }).to be_empty
  end
end

# Módulo 16 (ADR 0028): eventos declarados, só trilha.
RSpec.describe "record mode event bindings (ADR 0028)" do
  it "declares every module 16 city event with no consumer" do
    names = %w[integration_credential.changed cnes.proposals_applied citizen.cadsus_looked_up]
    expect(DomainEvents.registry.keys).to include(*names)
    expect(names.flat_map { |n| DomainEvents.registry[n] }).to be_empty
  end
end

# Módulo 16 (ADR 0028): eventos do exportador LEDI, só trilha.
RSpec.describe "ledi event bindings (ADR 0028)" do
  it "declares every exporter event with no consumer" do
    names = %w[ledi.ficha_accepted ledi.ficha_rejected ledi.ficha_resent]
    expect(DomainEvents.registry.keys).to include(*names)
    expect(names.flat_map { |n| DomainEvents.registry[n] }).to be_empty
  end
end

# Módulo 17 (ADR 0029): eventos da agenda declarados, só trilha.
RSpec.describe "scheduling event bindings (ADR 0029)" do
  it "declares every scheduling event with no consumer" do
    names = %w[appointment.booked appointment.fit_in_created appointment.reschedule_requested appointment.reminded
               appointment_request.created_from_triage appointment_request.merged_triage
               appointment_request.unit_assigned appointment_type.changed schedule_template.changed
               professional.shift_template_set professional.link_default_type_set]
    expect(DomainEvents.registry.keys).to include(*names)
    expect(names.flat_map { |n| DomainEvents.registry[n] }).to be_empty
  end
end

# Módulo 18 (ADR 0030): escuta e fichas não geradas, só trilha.
RSpec.describe "screening event bindings (ADR 0030)" do
  it "declares every module 18 city event with no consumer" do
    names = %w[screening.started screening.abandoned screening.completed screening.reassessed screening.viewed
               ledi.generation_failed ledi.generation_retried ledi.payload_purged]
    expect(DomainEvents.registry.keys).to include(*names)
    expect(names.flat_map { |n| DomainEvents.registry[n] }).to be_empty
  end
end
