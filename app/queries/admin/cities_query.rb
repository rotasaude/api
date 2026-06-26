# GET /admin/api/cities — catálogo de cidades provisionadas + resumo de atividade.
# Volumes respeitam o período; estado (canal, última atividade, conversas/protocolos
# ativos) é point-in-time. Agregação live cross-tenant — roda sob rota_admin
# (BYPASSRLS) via with_admin_connection do controller. Sem N+1: uma query
# agrupada por métrica, costurada por municipality_id.
class Admin::CitiesQuery
  ACTIVE_CONVERSATION_STATES = %w[greeting awaiting_consent consented].freeze

  def self.call(period:)
    new(period).call
  end

  def initialize(period)
    @from = period.from
    @to = period.to
  end

  def call
    munis = Municipality.order(:name).to_a

    conversations_active = Conversation.where(state: ACTIVE_CONVERSATION_STATES).group(:municipality_id).count
    triages_done         = Triage.where(status: "completed", completed_at: @from..@to).group(:municipality_id).count
    triages_in_progress  = Triage.where(status: "in_progress").group(:municipality_id).count
    inbound              = InboundMessage.where(created_at: @from..@to).group(:municipality_id).count
    outbound             = OutboundMessage.where(created_at: @from..@to).group(:municipality_id).count
    consents             = Consent.where(given_at: @from..@to).group(:municipality_id).count
    events               = DomainEvent.where(occurred_at: @from..@to).group(:municipality_id).count
    protocols_active     = ProtocolDefinition.where(status: "active").where.not(municipality_id: nil).group(:municipality_id).count
    channels             = MunicipalityChannel.order(:created_at).group_by(&:municipality_id)
    last_inbound         = InboundMessage.group(:municipality_id).maximum(:created_at)
    last_outbound        = OutboundMessage.group(:municipality_id).maximum(:created_at)
    last_event           = DomainEvent.group(:municipality_id).maximum(:occurred_at)

    munis.map do |m|
      channel = channels[m.id]&.find(&:active) || channels[m.id]&.first
      last_activity = [ last_inbound[m.id], last_outbound[m.id], last_event[m.id] ].compact.max
      {
        id: m.id,
        name: m.name,
        uf: m.uf,
        slug: m.slug,
        status: m.status,
        channel: channel && { active: channel.active, display_phone_number: channel.display_phone_number },
        last_activity_at: last_activity&.iso8601,
        metrics: {
          conversations_active: conversations_active[m.id] || 0,
          protocols_active:     protocols_active[m.id] || 0,
          triages_done:         triages_done[m.id] || 0,
          triages_in_progress:  triages_in_progress[m.id] || 0,
          inbound:              inbound[m.id] || 0,
          outbound:             outbound[m.id] || 0,
          consents:             consents[m.id] || 0,
          events:               events[m.id] || 0
        }
      }
    end
  end
end
