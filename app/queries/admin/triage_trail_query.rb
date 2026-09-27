# GET /admin/api/triages/:id/trail — trilha de classificação (§4.5b).
#
# CRÍTICO LGPD (§2.1 do brief / ADR 0009): apenas regras e referências,
# NUNCA texto clínico livre. Lê a explicação que o motor congelou no Outcome
# da triagem (F-03.7) — a mesma versão do protocolo em que a triagem terminou.
# Triagem concluída antes da explicação existir devolve steps vazio.
class Admin::TriageTrailQuery
  TRAIL_EVENTS = %w[scored rule_matched priority_rule tier_assigned].freeze

  def self.call(triage_id:)
    new(triage_id).call
  end

  def initialize(triage_id)
    @triage_id = triage_id
  end

  def call
    triage = Triage.all.find_by(id: @triage_id)
    return nil unless triage

    explanation = Array(triage.outcome&.dig("explanation"))

    {
      triageId: triage.id,
      protocol: "#{triage.protocol_name} · #{triage.protocol_definition.version}",
      mode: triage.protocol_definition.definition&.dig("scoring", "type"),
      steps: explanation.filter_map { |entry| step(entry, triage.completed_at) }
    }
  end

  private

  # Allowlist explícita — só ev/rule/ref/out, NUNCA a resposta.
  def step(entry, at)
    return nil unless entry.is_a?(Hash) && TRAIL_EVENTS.include?(entry["ev"])

    {
      ev: entry["ev"],
      rule: entry["rule"],
      ref: entry["ref"],
      out: entry["out"]&.to_s,
      at: at&.iso8601
    }
  end
end
