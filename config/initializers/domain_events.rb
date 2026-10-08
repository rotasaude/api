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
  DomainEvents.bind "consultation.finalized", to: []
  DomainEvents.bind "consultation.addendum_added", to: []
  DomainEvents.bind "clinical_record.viewed", to: []
  DomainEvents.bind "clinical_record.opened", to: []
end
