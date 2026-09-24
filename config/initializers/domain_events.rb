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

  DomainEvents.bind "consent.revoked", to: [AnonymizeRevokedTriageJob, RecordConsentRevocationJob]

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

  # Check-in e desfecho do atendimento (ADR 0018): trilha; sem consumidor, de
  # propósito.
  DomainEvents.bind "attendance.checked_in", to: []
  DomainEvents.bind "attendance.closed", to: []
end
