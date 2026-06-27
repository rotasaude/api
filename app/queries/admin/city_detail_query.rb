# Detalhe de uma cidade: recursos provisionados + KPIs (valor no período +
# sparkline via Period#series). Roda sob rota_admin (BYPASSRLS).
class Admin::CityDetailQuery
  def self.call(municipality:, period:)
    new(municipality, period).call
  end

  def initialize(municipality, period)
    @m = municipality
    @period = period
  end

  def call
    { city: city_block, resources: resources_block, kpis: kpis_block }
  end

  private

  def in_period(relation, col)
    relation.where(col => @period.from..@period.to)
  end

  def channel
    @channel ||= MunicipalityChannel.where(municipality_id: @m.id).order(created_at: :desc).find(&:active) ||
                 MunicipalityChannel.where(municipality_id: @m.id).order(created_at: :desc).first
  end

  def last_activity_at
    [ InboundMessage.where(municipality_id: @m.id).maximum(:created_at),
      OutboundMessage.where(municipality_id: @m.id).maximum(:created_at),
      DomainEvent.where(municipality_id: @m.id).maximum(:occurred_at) ].compact.max
  end

  def city_block
    {
      id: @m.id, name: @m.name, uf: @m.uf, slug: @m.slug,
      ibge_code: @m.ibge_code, status: @m.status,
      channel: channel && { active: channel.active, display_phone_number: channel.display_phone_number },
      last_activity_at: last_activity_at&.iso8601
    }
  end

  def resources_block
    term = ConsentTerm.where(municipality_id: @m.id).order(published_at: :desc).first
    first_admin = Membership.active.where(municipality_id: @m.id, role: "municipal_admin").order(:granted_at).first
    pending = Invitation.where(municipality_id: @m.id, role: "municipal_admin").order(created_at: :desc).first if first_admin.nil?
    {
      channel: channel && { display_phone_number: channel.display_phone_number, phone_number_id: channel.phone_number_id, active: channel.active },
      consent_term: term && { version: term.version, published_at: term.published_at.iso8601 },
      alert_recipients: AlertRecipient.where(municipality_id: @m.id, active: true).order(:escalation_order)
                          .map { |a| { channel: a.channel, destination: a.destination, escalation_order: a.escalation_order } },
      protocols_active: ProtocolDefinition.where(municipality_id: @m.id, status: "active").order(:name)
                          .map { |p| { name: p.name, version: p.version } },
      first_admin: first_admin_block(first_admin, pending)
    }
  end

  def first_admin_block(membership, pending)
    if membership
      { email: membership.user.email_address, status: "active" }
    elsif pending
      { email: pending.email, status: "invited" }
    end
  end

  def kpis_block
    triages_done = Triage.where(municipality_id: @m.id, status: "completed")
    inbound      = InboundMessage.where(municipality_id: @m.id)
    outbound     = OutboundMessage.where(municipality_id: @m.id)
    consents     = Consent.where(municipality_id: @m.id)
    events       = DomainEvent.where(municipality_id: @m.id)

    [
      kpi("triages_done", "Triagens concluídas", in_period(triages_done, :completed_at).count, @period.series(triages_done, :completed_at)),
      kpi("inbound",      "Mensagens recebidas", in_period(inbound, :created_at).count,         @period.series(inbound, :created_at)),
      kpi("outbound",     "Mensagens enviadas",  in_period(outbound, :created_at).count,        @period.series(outbound, :created_at)),
      kpi("consents",     "Consentimentos",      in_period(consents, :given_at).count,          @period.series(consents, :given_at)),
      kpi("events",       "Eventos",             in_period(events, :occurred_at).count,         @period.series(events, :occurred_at))
    ]
  end

  def kpi(id, label, value, spark)
    { id: id, label: label, value: value, spark: spark }
  end
end
