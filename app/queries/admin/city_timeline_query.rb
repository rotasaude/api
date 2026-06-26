# Timeline de domain_events de uma cidade (mais recentes primeiro).
class Admin::CityTimelineQuery
  def self.call(municipality:, limit: 50)
    DomainEvent
      .where(municipality_id: municipality.id)
      .order(occurred_at: :desc)
      .limit(limit)
      .map do |e|
        { at: e.occurred_at.iso8601, type: e.name, summary: summarize(e) }
      end
  end

  def self.summarize(event)
    return event.name if event.payload.blank?
    pairs = event.payload.first(3).map { |k, v| "#{k}: #{v}" }.join(" · ")
    pairs.presence || event.name
  end
end
