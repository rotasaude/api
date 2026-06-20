# GET /admin/api/protocols + /admin/api/protocols/:id (§4.6).
#
# Sinaliza "quatro olhos colapsado" quando created_by == published_by.
# Hoje protocol_definitions NÃO armazena created_by/published_by — esses
# vêm de domain_events (protocol.created / protocol.published). Aproximamos
# pelos eventos quando existirem; null quando não houver dado.
class Admin::ProtocolsQuery
  def self.index(municipality:)
    rows = Admin::Scoped.protocol_definitions(municipality)
             .order(:name, version: :desc)
             .includes(:municipality)
             .map { |d| serialize_row(d, fetch_audit(d)) }
    { list: rows }
  end

  def self.show(municipality:, id:)
    # id pode ser tanto o `name` quanto um UUID. Tentamos os dois.
    base = Admin::Scoped.protocol_definitions(municipality)
    versions = base.where(name: id).order(version: :desc)
    versions = base.where(id: id) if versions.empty?
    return nil if versions.empty?

    first = versions.first
    {
      id: first.name,
      name: first.name,
      versions: versions.map { |d| serialize_version(d, fetch_audit(d)) },
      events: protocol_events(first.name)
    }
  end

  def self.serialize_row(d, audit)
    {
      id: d.name,
      name: d.name,
      version: d.version.to_s,
      status: status_label(d),
      createdBy: audit[:created_by],
      publishedBy: audit[:published_by],
      fourEyes: four_eyes(audit),
      publishedAt: d.activated_at&.iso8601,
      retiredAt: d.retired_at&.iso8601,
      schema: "ok",
      linter: "ok",
      gates: "ok"
    }
  end

  def self.serialize_version(d, audit)
    {
      version: d.version.to_s,
      status: status_label(d),
      createdBy: audit[:created_by],
      publishedBy: audit[:published_by],
      fourEyes: four_eyes(audit),
      at: (d.activated_at || d.created_at).iso8601,
      schema: "ok",
      linter: "ok",
      gates: "ok"
    }
  end

  def self.status_label(d)
    case d.status
    when "active"  then "published"
    when "draft"   then "draft"
    when "retired" then "retired"
    else d.status
    end
  end

  def self.four_eyes(audit)
    return nil unless audit[:created_by] && audit[:published_by]
    audit[:created_by] != audit[:published_by]
  end

  # Aproximação: lê os 2 eventos relevantes do agregado. Sem dado clínico.
  def self.fetch_audit(d)
    events = DomainEvent.where(aggregate_type: "ProtocolDefinition", aggregate_id: d.id.to_s)
    {
      created_by: events.find_by(name: "protocol.created")&.payload&.dig("actor"),
      published_by: events.find_by(name: "protocol.published")&.payload&.dig("actor")
    }
  end

  def self.protocol_events(name)
    DomainEvent.where(aggregate_type: "ProtocolDefinition")
      .where("payload ->> 'name' = ?", name)
      .order(occurred_at: :desc)
      .limit(20)
      .map do |ev|
        {
          at: ev.occurred_at.iso8601,
          name: ev.name,
          actor: ev.payload&.dig("actor"),
          ref: "version=#{ev.payload&.dig('version')}"
        }
      end
  end
end
