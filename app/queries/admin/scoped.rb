# Helpers de escopo para queries do namespace Admin::.
#
# Multi-tenancy honesta: nem todas as tabelas têm `municipality_id`.
# Para cada modelo, expõe um scope que filtra quando faz sentido:
#
#   triages, consents → joinam via conversations.municipality_id
#   conversations, protocol_definitions, dashboard_metrics → coluna direta
#   inbound_messages, domain_events → SEM coluna de muni (gap conhecido,
#     ver RECONCILE.md). Por ora retornam cross-tenant — documentar no PR.
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

  # GAP: sem municipality_id. Cross-tenant até resolver via projeção/coluna.
  def self.inbound_messages(_municipality)
    InboundMessage.all
  end

  # GAP: sem municipality_id. Cross-tenant até resolver.
  def self.domain_events(_municipality)
    DomainEvent.all
  end
end
