# Cria ReportSnapshot imutável a partir de triagem.completed. Ver ADR-0007.
class GenerateReportJob < ApplicationJob
  include IdempotentConsumer
  queue_as :reports

  EXPIRATION = 30.days

  def consume(event)
    triagem = Triagem.find(event.aggregate_id)
    return if triagem.report_snapshot   # belongs_to inverso: defesa em profundidade

    token = ReportSnapshot.mint_token
    ReportSnapshot.create!(
      triagem: triagem,
      protocol_definition: triagem.protocol_definition,
      outcome: event.payload,
      payload: build_payload(triagem),
      token: token,
      signature: ReportSnapshot.sign(token),
      expires_at: Time.current + EXPIRATION
    )
  end

  private

  def build_payload(triagem)
    {
      tier: triagem.tier,
      priority: triagem.priority,
      summary: triagem.outcome.dig("trail")&.map { |e| { step: e["step"], answer: e["answer"] } },
      completed_at: triagem.completed_at&.iso8601
    }
  end
end
