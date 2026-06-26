# GET /admin/api/triages/:id/trail — trilha de classificação (§4.5b).
#
# CRÍTICO LGPD (§2.1 do brief / ADR 0015): apenas regras e referências,
# NUNCA texto clínico livre. Lemos de domain_events para esse aggregate.
class Admin::TriageTrailQuery
  TRAIL_EVENTS = %w[scored rule_matched priority_rule tier_assigned].freeze

  def self.call(municipality:, triage_id:)
    new(municipality, triage_id).call
  end

  def initialize(municipality, triage_id)
    @muni = municipality
    @triage_id = triage_id
  end

  def call
    triage = Admin::Scoped.triages(@muni).find_by(id: @triage_id)
    return nil unless triage

    # Phase 2.1 dropou domain_events.aggregate_type/aggregate_id;
    # IDs viajam no payload JSON (ADR-0020).
    events = DomainEvent
               .where("payload ->> 'triage_id' = ?", triage.id.to_s)
               .where(name: TRAIL_EVENTS)
               .order(:occurred_at)

    {
      triageId: triage.id,
      protocol: "#{triage.protocol_name} · #{triage.protocol_definition.version}",
      mode: triage.outcome&.dig("scoring", "mode"),
      steps: events.map { |ev| step(ev) }
    }
  end

  private

  # Allowlist explícita do payload — só rule/ref/out, NUNCA texto livre.
  def step(ev)
    p = ev.payload || {}
    {
      ev: ev.name,
      rule: p["rule"],
      ref: p["ref"],
      out: p["out"],
      at: ev.occurred_at.iso8601
    }
  end
end
