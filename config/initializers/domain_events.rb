# Bindings evento → consumer. Ver ADR-0004.
# Adicionar consumidor = uma linha aqui + queue_as no job.
Rails.application.config.to_prepare do
  DomainEvents.registry.clear

  DomainEvents.bind "triage.completed", to: [GenerateReportJob, UpdateDashboardJob, NotifyCitizenJob]

  # published_at só é marcado quando o PRIMEIRO (e único) consumer termina com
  # sucesso (ver IdempotentConsumer) — não quando o evento é apenas
  # enfileirado. ResendPendingAlertsJob confia nisso: ele redespacha todo
  # triage.urgent com published_at IS NULL. Ligar um segundo consumer aqui
  # divide essa garantia entre dois "primeiros terminam", enfraquecendo a rede
  # de segurança do resend sem levantar erro nenhum.
  DomainEvents.bind "triage.urgent", to: AlertMunicipalityJob

  # Eventos só de auditoria — sem consumidores. A linha existe para tornar
  # explícito que ninguém escuta, e não por esquecimento.
  DomainEvents.bind "consent.given",   to: []

  DomainEvents.bind "consent.revoked", to: [AnonymizeRevokedTriageJob, RecordConsentRevocationJob, ForgetRevokedTriageMetricsJob]

  # A2 (fix final do autenticador pendente): auditoria da promoção do segundo
  # fator (Mfa::PendingEnrollment#confirm). Sem consumidor, de propósito.
  DomainEvents.bind "user.authenticator_replaced", to: []

  # F2 (final-fix-brief.md): auditoria do uso de código de recuperação para
  # aprovar step-up (MfaController#step_up). Sem consumidor, de propósito —
  # mesmo caso de user.authenticator_replaced acima.
  DomainEvents.bind "user.recovery_code_used", to: []

  # Validação presencial (spec 2026-09-24): trilha; a prova é citizen_verifications.
  DomainEvents.bind "citizen.verified", to: []
  DomainEvents.bind "citizen.verification_revoked", to: []

  # Exclusão do cadastro (ADR 0026): trilha do pedido; payload só {request_id}.
  DomainEvents.bind "citizen.erasure_requested", to: []
  DomainEvents.bind "citizen.erasure_retained", to: []
  DomainEvents.bind "citizen.erasure_rejected", to: []
  DomainEvents.bind "citizen.erased", to: []

  # Check-in e desfecho do atendimento (ADR 0018): trilha; sem consumidor, de
  # propósito.
  DomainEvents.bind "attendance.checked_in", to: []
  DomainEvents.bind "attendance.closed", to: []

  # Chamada e pedido de agendamento (spec 2026-09-25): trilha; sem
  # consumidor, de propósito.
  DomainEvents.bind "attendance.called", to: []
  DomainEvents.bind "appointment_request.created", to: []
  DomainEvents.bind "appointment_request.closed", to: []
  DomainEvents.bind "appointment.scheduled", to: []
  DomainEvents.bind "appointment.checked_in", to: []
  DomainEvents.bind "appointment.confirmed", to: []
  DomainEvents.bind "appointment.cancelled", to: []
  DomainEvents.bind "appointment.expired", to: []
  DomainEvents.bind "appointment.no_show", to: []
  DomainEvents.bind "appointment.reminder_recorded", to: []
  DomainEvents.bind "appointment.moved", to: []
  DomainEvents.bind "appointment_request.moved", to: []
  DomainEvents.bind "health_unit.drained", to: []
  # Agenda dos profissionais (ADR 0029; contratos §6): trilha, só ids, sem consumidor.
  DomainEvents.bind "appointment.booked", to: []
  DomainEvents.bind "appointment.fit_in_created", to: []
  DomainEvents.bind "appointment.reschedule_requested", to: []
  DomainEvents.bind "appointment.reminded", to: []
  DomainEvents.bind "appointment_request.created_from_triage", to: []
  DomainEvents.bind "appointment_request.merged_triage", to: []
  DomainEvents.bind "appointment_request.unit_assigned", to: []
  DomainEvents.bind "appointment_type.changed", to: []
  DomainEvents.bind "schedule_template.changed", to: []
  DomainEvents.bind "professional.shift_template_set", to: []
  DomainEvents.bind "professional.link_default_type_set", to: []

  # ADR 0018: rastro LGPD da busca por exceção (POST check_ins/search) — expõe
  # dado de saúde sem código; sem CPF no payload, sem consumidor, de propósito.
  DomainEvents.bind "attendance.exception_searched", to: []

  # Profissionais (ADR 0021; spec 2026-09-27): trilha, só ids; sem consumidor,
  # de propósito.
  DomainEvents.bind "professional.created", to: []
  DomainEvents.bind "professional.profile_updated", to: []
  DomainEvents.bind "professional.linked", to: []
  DomainEvents.bind "professional.unlinked", to: []
  DomainEvents.bind "professional.shift_scheduled", to: []
  DomainEvents.bind "professional.shift_cancelled", to: []

  # Território (ADR 0023; spec 2026-09-28 §3.5): trilha, só ids; sem
  # consumidor, de propósito.
  DomainEvents.bind "neighborhood.created", to: []
  DomainEvents.bind "neighborhood.renamed", to: []
  DomainEvents.bind "neighborhood.deactivated", to: []
  DomainEvents.bind "neighborhood.activated", to: []
  DomainEvents.bind "neighborhood.coverage_changed", to: []
  DomainEvents.bind "citizen.neighborhood_changed", to: []

  # Campanhas (ADR 0024; spec 2026-09-29 §5.7): trilha, só ids, contagens,
  # booleanos e o público (JSON sem dado pessoal); sem consumidor, de propósito.
  DomainEvents.bind "campaign.created", to: []
  DomainEvents.bind "campaign.scheduled", to: []
  DomainEvents.bind "campaign.unscheduled", to: []
  DomainEvents.bind "campaign.cancelled", to: []
  DomainEvents.bind "campaign.dispatched", to: []
  DomainEvents.bind "campaign.failed", to: []
  DomainEvents.bind "campaign.sms_unavailable", to: []
  DomainEvents.bind "citizen.contact_preferences_changed", to: []
  DomainEvents.bind "city.campaigns_sms_toggled", to: []

  # Catálogo de triagens (ADR 0027; spec 2026-10-05 §3–§5): trilha, só ids e
  # nome de protocolo; nunca data de nascimento, idade, sexo ou identidade de
  # gênero. Sem consumidor, de propósito.
  DomainEvents.bind "citizen.profile_changed", to: []
  DomainEvents.bind "triage.suggested", to: []
  DomainEvents.bind "triage_offer.changed", to: []

  # Módulo 16 (ADR 0028): trilha; payload só com ids. Sem consumidor.
  DomainEvents.bind "integration_credential.changed", to: []
  DomainEvents.bind "cnes.proposals_applied", to: []
  DomainEvents.bind "citizen.cadsus_looked_up", to: []

  # Exportador LEDI (ADR 0028; contratos §6): só trilha, só ids.
  DomainEvents.bind "ledi.ficha_accepted", to: []
  DomainEvents.bind "ledi.ficha_rejected", to: []
  DomainEvents.bind "ledi.ficha_resent", to: []

  # Módulo 18 (ADR 0030; contratos §7): escuta e fichas não geradas; só trilha,
  # só ids. Nenhum texto livre da escuta entra em evento.
  DomainEvents.bind "screening.started", to: []
  DomainEvents.bind "screening.abandoned", to: []
  DomainEvents.bind "screening.completed", to: []
  DomainEvents.bind "screening.reassessed", to: []
  DomainEvents.bind "screening.viewed", to: []
  DomainEvents.bind "ledi.generation_failed", to: []
  DomainEvents.bind "ledi.generation_retried", to: []
  DomainEvents.bind "ledi.payload_purged", to: []

  # Módulo 19 (ADR 0031; contratos §7): prontuário; só trilha, só ids. Nenhum
  # texto clínico, nota de abertura ou nome entra em evento.
  DomainEvents.bind "patient.created", to: []
  DomainEvents.bind "patient.linked", to: []
  DomainEvents.bind "patient_problem.changed", to: []
  DomainEvents.bind "consultation.started", to: []
  # ADR 0032 (19b): a finalização e o adendo abrem o pedido de assinatura
  # (Signatures::RequestJob só abre o pedido e enfileira; o 19a não muda).
  DomainEvents.bind "consultation.finalized", to: [ Signatures::RequestJob ]
  DomainEvents.bind "consultation.addendum_added", to: [ Signatures::RequestJob ]
  DomainEvents.bind "clinical_record.viewed", to: []
  DomainEvents.bind "clinical_record.opened", to: []
  # ADR 0035: página do PEC, só trilha (ids e código do motivo).
  DomainEvents.bind "pec.external_view_opened", to: []
  DomainEvents.bind "pec.external_view_denied", to: []
  # Rascunho órfão (card api#51): descarte e designação pelo admin municipal;
  # só ids, nunca o motivo nem texto clínico.
  DomainEvents.bind "consultation.draft_discarded", to: []
  DomainEvents.bind "consultation.draft_reassigned", to: []

  # Módulo 19b (ADR 0032; contrato §11): assinatura digital; trilha, só ids.
  # Nenhum token, CPF, nome ou conteúdo assinado entra em evento.
  DomainEvents.bind "signature.certificate_linked", to: []
  DomainEvents.bind "signature.certificate_unlinked", to: []
  DomainEvents.bind "signature.session_opened", to: []
  DomainEvents.bind "signature.signed", to: []
  DomainEvents.bind "signature.failed", to: []
  DomainEvents.bind "signature.returned_to_paper", to: []
  DomainEvents.bind "signature.verified", to: []

  # Módulo 19c (ADR 0033): documentos clínicos e lista de medicamentos, só trilha.
  DomainEvents.bind "clinical_document.issued", to: []
  DomainEvents.bind "clinical_document.cancelled", to: []
  DomainEvents.bind "patient_medication.changed", to: []

  # Módulo 19d (ADR 0034): estoque SNCR e registro da Notificação — só ids.
  DomainEvents.bind "sncr.numbers_requested", to: []
  DomainEvents.bind "sncr.number_used", to: []
  DomainEvents.bind "sncr.number_voided", to: []
  DomainEvents.bind "controlled_notification.recorded", to: []

  # Módulo 21a (ADR 0036; contrato §12): só ids — nunca valor de resultado,
  # nome do exame com o paciente, CPF, motivo ou token.
  %w[requested authorized denied scheduled collected resulted acknowledged escalated cancelled].each do |kind|
    DomainEvents.bind "exam_order.#{kind}", to: []
  end
  DomainEvents.bind "exam_result.external_recorded", to: []
  DomainEvents.bind "exam.patient_looked_up", to: []
  DomainEvents.bind "exam_provider.fhir_token_rotated", to: []
  DomainEvents.bind "exam_provider.fhir_token_revoked", to: []

  # Módulo 21b (ADR 0037): laboratório municipal, só trilha, só ids. Nunca
  # valor, nome, CPF, mensagem HL7 ou token.
  %w[lab_requisition.opened lab_requisition.delivered lab_sample.collected lab_sample.received lab_sample.rejected
     lab_sample.label_printed lab_shipment.sent lab_shipment.received lab_result.entered
     lab_report.rectified lab_report.withdrawn lab_critical.notified lab_exam.version_created lab_releaser.assigned
     lab_releaser.ended lab_middleware.token_rotated lab_middleware.token_revoked exam_order.result_rectified
     exam_order.gal_registered].each { |name| DomainEvents.bind name, to: [] }

  # ADR 0039 (contrato §4): a liberação do PRIMEIRO laudo vira produção do
  # laboratório municipal (Billing::FromLab; idempotente por item).
  DomainEvents.bind "lab_report.released", to: [ Billing::LabProductionJob ]

  # Módulo 21c (ADR 0038): qualidade e insumos, só trilha, só ids. Nunca
  # valor de controle, valor de resultado, justificativa ou nome.
  %w[lab_qc_run.evaluated lab_qc_block.opened lab_qc_block.closed lab_qc_block.action_recorded lab_qc_exception.granted
     lab_qc_review.decided lab_qc_target.accepted lab_qc_rule.changed lab_eqa_round.recorded lab_eqa_annual_report.recorded lab_supply_lot.received
     lab_supply_lot.traced lab_supply_movement.recorded lab_supply_in_use.changed].each { |name| DomainEvents.bind name, to: [] }

  # Módulo 22 (ADR 0039): procedimentos e faturamento, só trilha, só ids (e
  # source/billable/version; procedure_ids na leitura da lista, §13 E19).
  # Nunca CPF, CNS, nome, motivo ou arquivo.
  %w[performed_procedure.recorded performed_procedure.cancelled billing_period.closed billing_period.reopened
     billing_period.pending_viewed billing_export.generated billing_export.downloaded billing_settings.changed
     billing_patient.looked_up billing_patient.demographics_updated patient.demographics_updated
     billing_procedures.listed].each { |name| DomainEvents.bind name, to: [] }

  # ADR 0040 (contrato §9): linhas de cuidado, só ids. O problema que muda e a
  # condição declarada disparam a sugestão daquela pessoa (Task 10).
  DomainEvents.bind "care_line.adopted", to: []
  DomainEvents.bind "care_line_suggestion.created", to: []
  DomainEvents.bind "care_line_suggestion.accepted", to: []
  DomainEvents.bind "care_line_suggestion.dismissed", to: []
  DomainEvents.bind "care_line_enrollment.created", to: []
  DomainEvents.bind "care_line_enrollment.ended", to: []
  DomainEvents.bind "care_outreach.recorded", to: []
  DomainEvents.bind "citizen_condition.withdrawn", to: []
end
