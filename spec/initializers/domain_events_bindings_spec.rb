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

# Módulo 19 (ADR 0031): prontuário, só trilha.
RSpec.describe "clinical record event bindings (ADR 0031)" do
  it "declares every module 19 city event with no consumer" do
    names = %w[patient.created patient.linked patient_problem.changed consultation.started
               clinical_record.viewed clinical_record.opened]
    expect(DomainEvents.registry.keys).to include(*names)
    expect(names.flat_map { |n| DomainEvents.registry[n] }).to be_empty
  end
end

# Módulo 19b (ADR 0032): a finalização e o adendo abrem o pedido de assinatura.
RSpec.describe "consultation signature bindings (ADR 0032)" do
  it "binds consultation.finalized and consultation.addendum_added to Signatures::RequestJob" do
    %w[consultation.finalized consultation.addendum_added].each do |name|
      expect(DomainEvents.registry[name].map(&:job)).to eq([ "Signatures::RequestJob" ])
    end
  end
end

# Módulo 19b (ADR 0032): assinatura digital, só trilha.
RSpec.describe "digital signature event bindings (ADR 0032)" do
  it "declares every module 19b event with no consumer" do
    names = %w[signature.certificate_linked signature.certificate_unlinked signature.session_opened signature.signed
               signature.failed signature.returned_to_paper signature.verified]
    expect(DomainEvents.registry.keys).to include(*names)
    expect(names.flat_map { |n| DomainEvents.registry[n] }).to be_empty
  end
end

# Módulo 19c (ADR 0033): documentos clínicos, só trilha.
RSpec.describe "clinical document event bindings (ADR 0033)" do
  it "declares every module 19c event with no consumer" do
    names = %w[clinical_document.issued clinical_document.cancelled patient_medication.changed]
    expect(DomainEvents.registry.keys).to include(*names)
    expect(names.flat_map { |n| DomainEvents.registry[n] }).to be_empty
  end
end

# Módulo 19d (ADR 0034): estoque SNCR e registro da Notificação, só trilha.
RSpec.describe "controlled prescription event bindings (ADR 0034)" do
  it "declares every module 19d event with no consumer" do
    names = %w[sncr.numbers_requested sncr.number_used sncr.number_voided controlled_notification.recorded]
    expect(DomainEvents.registry.keys).to include(*names)
    expect(names.flat_map { |n| DomainEvents.registry[n] }).to be_empty
  end
end

# Módulo 20 (ADR 0035): página do PEC, só trilha.
RSpec.describe "patient timeline event bindings (ADR 0035)" do
  it "declares every module 20 city event with no consumer" do
    names = %w[clinical_record.viewed pec.external_view_opened pec.external_view_denied]
    expect(DomainEvents.registry.keys).to include(*names)
    expect(names.flat_map { |n| DomainEvents.registry[n] }).to be_empty
  end
end

# Módulo 21a (ADR 0036): rastreamento do exame, só trilha.
RSpec.describe "exam event bindings (ADR 0036)" do
  it "declares every exam event with no consumer" do
    names = %w[requested authorized denied scheduled collected resulted acknowledged escalated cancelled].map { |k| "exam_order.#{k}" } +
            %w[exam_result.external_recorded exam_provider.fhir_token_rotated exam_provider.fhir_token_revoked exam.patient_looked_up]
    expect(DomainEvents.registry.keys).to include(*names)
    expect(names.flat_map { |n| DomainEvents.registry[n] }).to be_empty
  end
end

# Módulo 21b (ADR 0037; contrato §11 e B19): laboratório municipal, só trilha.
RSpec.describe "municipal lab event bindings (ADR 0037)" do
  it "declares every lab event with no consumer" do
    names = %w[lab_requisition.opened lab_requisition.delivered lab_sample.collected lab_sample.received lab_sample.rejected
               lab_sample.label_printed lab_shipment.sent lab_shipment.received lab_result.entered
               lab_report.rectified lab_report.withdrawn lab_critical.notified lab_exam.version_created lab_releaser.assigned
               lab_releaser.ended lab_middleware.token_rotated lab_middleware.token_revoked exam_order.result_rectified
               exam_order.gal_registered]
    expect(DomainEvents.registry.keys).to include(*names)
    expect(names.flat_map { |n| DomainEvents.registry[n] }).to be_empty
  end

  # ADR 0039: a liberação do laudo vira produção do laboratório municipal.
  it "binds lab_report.released only to the billing consumer" do
    expect(DomainEvents.registry["lab_report.released"].map(&:job)).to eq([ "Billing::LabProductionJob" ])
  end
end

# Módulo 21c (ADR 0038): qualidade e insumos do laboratório, só trilha.
RSpec.describe "lab quality and supplies event bindings (ADR 0038)" do
  it "declares every quality and supplies event with no consumer" do
    names = %w[lab_qc_run.evaluated lab_qc_block.opened lab_qc_block.closed lab_qc_block.action_recorded lab_qc_exception.granted
               lab_qc_review.decided lab_qc_target.accepted lab_qc_rule.changed lab_eqa_round.recorded lab_eqa_annual_report.recorded lab_supply_lot.received
               lab_supply_lot.traced lab_supply_movement.recorded lab_supply_in_use.changed]
    expect(DomainEvents.registry.keys).to include(*names)
    expect(names.flat_map { |n| DomainEvents.registry[n] }).to be_empty
  end
end

# Módulo 22 (ADR 0039): eventos do faturamento declarados, só trilha.
RSpec.describe "billing event bindings (ADR 0039)" do
  it "declares every billing event with no consumer" do
    names = %w[performed_procedure.recorded performed_procedure.cancelled billing_period.closed billing_period.reopened
               billing_period.pending_viewed billing_export.generated billing_export.downloaded billing_settings.changed
               billing_patient.looked_up billing_patient.demographics_updated patient.demographics_updated]
    expect(DomainEvents.registry.keys).to include(*names)
    expect(names.flat_map { |n| DomainEvents.registry[n] }).to be_empty
  end
end
