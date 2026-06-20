# Helpers de escopo para queries do namespace Admin::.
#
# Multi-tenancy honesta: nem todas as tabelas têm `municipality_id`.
# Para cada modelo, expõe um scope que filtra quando faz sentido:
#
#   triages, consents → joinam via conversations.municipality_id
#   conversations, protocol_definitions, dashboard_metrics → coluna direta
#   inbound_messages, domain_events → muni direto (Phase 1.4/2.1). RLS sob
#     SET LOCAL faz o escopo automaticamente quando chamado de within_tenant.
module Admin::Scoped
  def self.triages(municipality)
    return Triagem.all if municipality == :all || municipality.nil?
    Triagem.joins(:conversation).where(conversations: { municipality_id: municipality.id })
  end

  def self.conversations(municipality)
    return Conversation.all if municipality == :all || municipality.nil?
    Conversation.where(municipality_id: municipality.id)
  end

  def self.consents(municipality)
    return Consent.all if municipality == :all || municipality.nil?
    Consent.joins(:conversation).where(conversations: { municipality_id: municipality.id })
  end

  def self.protocol_definitions(municipality)
    return ProtocolDefinition.all if municipality == :all || municipality.nil?
    ProtocolDefinition.where(municipality_id: [ municipality.id, nil ])
  end

  def self.dashboard_metrics(municipality)
    return DashboardMetric.all if municipality == :all || municipality.nil?
    DashboardMetric.where(municipality_id: municipality.id)
  end

  # Phase 1.4 adicionou municipality_id + RLS — sob SET LOCAL do request
  # já vem escopado. Filtro explícito mantido para clareza e chamada admin
  # sem tenant (returns :all).
  def self.inbound_messages(municipality)
    return InboundMessage.all if municipality == :all || municipality.nil?
    InboundMessage.where(municipality_id: municipality.id)
  end

  # Phase 1.4 + 4.1: muni_id existe (nullable para platform-scope).
  def self.domain_events(municipality)
    return DomainEvent.all if municipality == :all || municipality.nil?
    DomainEvent.where(municipality_id: municipality.id)
  end
end
