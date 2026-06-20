# Tabela de bindings: event_name => [JobClass, ...]
# Único lugar onde a relação produtor → consumidor é declarada. Ver ADR-0003.
# Adicionar consumidor = uma linha aqui + queue_as no job.

Rails.application.config.to_prepare do
  Events.bindings.clear

  Events.bind "inbound_message.received", to: ProcessInboundMessageJob

  Events.bind "triagem.completed", to: [
    GenerateReportJob,
    UpdateDashboardJob,
    NotifyCitizenJob
  ]

  Events.bind "triagem.urgent", to: AlertMunicipalityJob

  # Eventos só de auditoria — sem consumidores. A linha existe para tornar
  # explícito que ninguém escuta, e não por esquecimento.
  Events.bind "consent.given",   to: []
  Events.bind "consent.revoked", to: []
end
