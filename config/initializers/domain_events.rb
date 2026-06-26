# Bindings evento → consumer. Ver ADR-0003 + ADR-0020.
# Adicionar consumidor = uma linha aqui + queue_as no job.
Rails.application.config.to_prepare do
  DomainEvents.registry.clear

  DomainEvents.bind "triage.completed", to: [GenerateReportJob, UpdateDashboardJob, NotifyCitizenJob]

  DomainEvents.bind "triage.urgent", to: AlertMunicipalityJob

  # Eventos só de auditoria — sem consumidores. A linha existe para tornar
  # explícito que ninguém escuta, e não por esquecimento.
  DomainEvents.bind "consent.given",   to: []
  DomainEvents.bind "consent.revoked", to: []
end
