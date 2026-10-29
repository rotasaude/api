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
    names = %w[appointment.fit_in_created appointment.reschedule_requested appointment.reminded
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
  it "declares every module 19 city event, with no consumer except patient_problem.changed (ADR 0040)" do
    names = %w[patient.created patient.linked consultation.started clinical_record.viewed clinical_record.opened]
    expect(DomainEvents.registry.keys).to include("patient_problem.changed")
    expect(DomainEvents.registry.keys).to include(*names)
    expect(names.flat_map { |n| DomainEvents.registry[n] }).to be_empty
  end
end

# Módulo 19b (ADR 0032): a finalização e o adendo abrem o pedido de assinatura;
# módulo 25 (ADR 0043): e passam pela rede de segurança da vigilância.
RSpec.describe "consultation signature and surveillance bindings (ADR 0032, ADR 0043)" do
  it "binds consultation.finalized and consultation.addendum_added to Signatures::RequestJob and Surveillance::SafetyNetJob" do
    %w[consultation.finalized consultation.addendum_added].each do |name|
      expect(DomainEvents.registry[name].map(&:job)).to eq([ "Signatures::RequestJob", "Surveillance::SafetyNetJob" ])
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
               billing_patient.looked_up billing_patient.demographics_updated patient.demographics_updated billing_procedures.listed]
    expect(DomainEvents.registry.keys).to include(*names)
    expect(names.flat_map { |n| DomainEvents.registry[n] }).to be_empty
  end
end

# Módulo 23 (ADR 0040; contrato §9): trilha das linhas de cuidado, só ids.
RSpec.describe "care lines bindings (F-23.3, F-23.5, F-23.7)" do
  it "declara os eventos das linhas de cuidado" do
    %w[care_line.adopted care_line_suggestion.created care_line_suggestion.accepted care_line_suggestion.dismissed
       care_line_enrollment.created care_line_enrollment.ended care_outreach.recorded citizen_condition.withdrawn citizen_condition.declared].each do |name|
      expect(DomainEvents.registry.key?(name)).to be(true), name
    end
  end

  it "liga o problema que muda e a condição declarada às sugestões (Task 10)" do
    expect(DomainEvents.registry["patient_problem.changed"].map(&:job)).to eq([ "CareLines::ProblemChangedJob" ])
    expect(DomainEvents.registry["citizen_condition.declared"].map(&:job)).to eq([ "CareLines::ConditionDeclaredJob" ])
  end
end

# Módulo 24a (ADR 0042): cadastro territorial, só trilha, só ids. Nunca CPF,
# CNS, nome, nascimento ou justificativa sem CPF.
RSpec.describe "territory registry bindings (ADR 0042)" do
  it "declares every territory registry event with no consumer" do
    names = %w[patient.cpf_added micro_area.changed household.saved territory_registration.saved family.responsible_replaced]
    expect(DomainEvents.registry.keys).to include(*names)
    expect(names.flat_map { |n| DomainEvents.registry[n] }).to be_empty
  end

  it "liga a saída do cadastro às linhas de cuidado (L30)" do
    expect(DomainEvents.registry["territory_registration.exited"].map(&:job)).to eq([ "CareLines::RegistrationExitedJob" ])
  end
end

# Módulo 25 (ADR 0043): doenças locais de notificação, só trilha, só ids.
RSpec.describe "disease surveillance bindings (ADR 0043)" do
  it "declares local_disease.changed with no consumer" do
    expect(DomainEvents.registry.keys).to include("local_disease.changed")
    expect(DomainEvents.registry["local_disease.changed"]).to be_empty
  end

  # Só ids e booleanos (notification_id, immediate): nunca a doença, a origem
  # nem dado do paciente. O consumidor (Surveillance::AlertJob) só enfileira o e-mail.
  it "declares disease_notification.created consumed by the surveillance alert" do
    expect(DomainEvents.registry.keys).to include("disease_notification.created")
    expect(DomainEvents.registry["disease_notification.created"].map(&:job)).to eq([ "Surveillance::AlertJob" ])
  end

  # Só notification_id (Surveillance::SaveForm): nunca a ficha.
  it "declares disease_notification.updated (no consumer)" do
    expect(DomainEvents.registry.keys).to include("disease_notification.updated")
    expect(DomainEvents.registry["disease_notification.updated"]).to be_empty
  end

  # Só notification_id e user_id (Surveillance::Transition / Dismiss): nunca o
  # motivo, a classificação nem o número oficial.
  %w[disease_notification.transitioned disease_notification.dismissed].each do |name|
    it "declares #{name} (no consumer)" do
      expect(DomainEvents.registry.keys).to include(name)
      expect(DomainEvents.registry[name]).to be_empty
    end
  end

  # Só weekly_negative_report_id e user_id (Surveillance::RecordNegative).
  it "declares weekly_negative.recorded (no consumer)" do
    expect(DomainEvents.registry.keys).to include("weekly_negative.recorded")
    expect(DomainEvents.registry["weekly_negative.recorded"]).to be_empty
  end
end

# Módulo 26a (ADR 0044): configuração da regulação (prazos e lista do enfermeiro).
RSpec.describe "care regulation bindings (ADR 0044)" do
  it "declares care_regulation.settings_changed with no consumer" do
    expect(DomainEvents.registry.keys).to include("care_regulation.settings_changed")
    expect(DomainEvents.registry["care_regulation.settings_changed"]).to be_empty
  end

  it "declares the regulation request, provider and offer events with no consumer" do
    names = %w[regulation_request.created regulation_request.complemented regulation_request.external
               regulation_request.authorized regulation_request.returned regulation_request.denied
               regulation_request.cancelled regulation_request.scheduled regulation_request.completed
               regulation_request.missed regulation_request.closed care_offer.changed care_provider.changed]
    names.each do |name|
      expect(DomainEvents.registry.keys).to include(name)
      expect(DomainEvents.registry[name]).to be_empty
    end
    transition_names = CareRegulation::Transition::EVENTS.map { |event| "regulation_request.#{event}" }
    expect(transition_names - names).to be_empty
  end

  # Task 10 (contrato §7, §13 G1, G6): a rede própria acompanha o 17 pelos
  # nove eventos do pedido de agendamento e do horário, mais o nascimento do
  # pedido (rede de segurança da corrida Cancelar × Drain).
  it "binds the scheduling events the own network follows to CareRegulation::AppointmentSyncJob only" do
    names = %w[appointment.scheduled appointment.checked_in appointment.no_show appointment.expired appointment.booked
               appointment.moved appointment.cancelled appointment_request.closed appointment_request.moved
               appointment_request.created]
    names.each do |name|
      expect(DomainEvents.registry[name].map(&:job)).to eq([ "CareRegulation::AppointmentSyncJob" ]), name
    end
    expect(CareRegulation::AppointmentSyncJob::EVENTS).to match_array(names)
    expect(DomainEvents.registry["appointment.confirmed"]).to be_empty
  end
end

# Módulo 27a (ADR 0045): configuração da farmácia (locais, equipe, parâmetros e
# mínimos); só trilha, só ids (subject, stock_location_id, staff_user_id,
# user_id), sem consumidor.
RSpec.describe "pharmacy bindings (ADR 0045)" do
  it "declares pharmacy.settings_changed with no consumer" do
    expect(DomainEvents.registry.keys).to include("pharmacy.settings_changed")
    expect(DomainEvents.registry["pharmacy.settings_changed"]).to be_empty
  end

  # Entrada de estoque (nota, doação, abertura); só ids (stock_entry_id,
  # user_id), sem consumidor.
  it "declares stock_receipt.recorded with no consumer" do
    expect(DomainEvents.registry.keys).to include("stock_receipt.recorded")
    expect(DomainEvents.registry["stock_receipt.recorded"]).to be_empty
  end

  # Transferência do central para a unidade (enviada e recebida); só ids
  # (stock_transfer_id, user_id; o recebimento leva também with_difference),
  # sem consumidor.
  it "declares stock_transfer.sent and stock_transfer.received with no consumer" do
    expect(DomainEvents.registry.keys).to include("stock_transfer.sent", "stock_transfer.received")
    expect(DomainEvents.registry["stock_transfer.sent"]).to be_empty
    expect(DomainEvents.registry["stock_transfer.received"]).to be_empty
  end
end
