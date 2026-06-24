# Cria ReportSnapshot imutável a partir de triage.completed. Ver ADR-0007.
class GenerateReportJob < ApplicationJob
  include IdempotentConsumer
  queue_as :reports

  EXPIRATION = 30.days

  def handle(triage_id:, **outcome)
    triage = Triage.find(triage_id)
    return if triage.report_snapshot   # belongs_to inverso: defesa em profundidade

    token = ReportSnapshot.mint_token
    ReportSnapshot.create!(
      triage: triage,
      protocol_definition: triage.protocol_definition,
      outcome: outcome,
      payload: build_payload(triage),
      token: token,
      signature: ReportSnapshot.sign(token),
      expires_at: Time.current + EXPIRATION
    )
  end

  private

  def build_payload(triage)
    {
      tier: triage.tier,
      priority: triage.priority,
      summary: triage.outcome.dig("trail")&.map { |e| { step: e["step"], answer: e["answer"] } },
      completed_at: triage.completed_at&.iso8601
    }
  end
end
