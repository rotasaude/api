require "rails_helper"

RSpec.describe GenerateReportJob do
  let(:muni) { create(:municipality) }

  def definition_hash(with_recs:)
    base = {
      "name" => "triagem-rec",
      "version" => 1,
      "start_step_id" => "tosse",
      "steps" => [
        { "id" => "tosse", "prompt" => "Tosse?", "answer_type" => "boolean",
          "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 5, "false" => 0 } }
      ],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0, "alta" => 5 },
                     "priority_map" => { "baixa" => 9, "alta" => 1 } }
    }
    return base unless with_recs
    base.merge("recommendations" => {
      "alta"  => { "title" => "Procure atendimento hoje", "body" => "Seus sintomas indicam prioridade alta." },
      "baixa" => { "title" => "Cuidados em casa", "body" => "Mantenha repouso e hidratacao." }
    })
  end

  def build_triage(tier:, with_recs:)
    pd = ProtocolDefinition.create!(
      name: "triagem-rec", version: 1, status: "active",
      definition: definition_hash(with_recs: with_recs), municipality_id: muni.id
    )
    convo = Conversation.create!(municipality_id: muni.id, phone: "+5511999990000", state: "greeting")
    Triage.create!(
      conversation: convo, protocol_definition: pd, protocol_name: "triagem-rec",
      municipality_id: muni.id, status: "completed", tier: tier, priority: 1,
      completed_at: Time.current,
      outcome: { "trail" => [{ "step" => "tosse", "answer" => "true" }] }
    )
  end

  around do |ex|
    ApplicationRecord.transaction do
      Current.municipality_id = muni.id
      ApplicationRecord.connection.execute(
        ApplicationRecord.sanitize_sql(["SET LOCAL app.municipality_id = ?", muni.id])
      )
      ex.run
      raise ActiveRecord::Rollback
    end
  end

  after { Current.reset }

  it "freezes the tier's recommendation into the payload" do
    triage = build_triage(tier: "alta", with_recs: true)
    GenerateReportJob.new.handle(triage_id: triage.id)
    snap = ReportSnapshot.find_by!(triage_id: triage.id)
    expect(snap.payload["recommendation"]).to eq(
      "title" => "Procure atendimento hoje", "body" => "Seus sintomas indicam prioridade alta."
    )
  end

  it "freezes nil when the protocol has no recommendations" do
    triage = build_triage(tier: "alta", with_recs: false)
    GenerateReportJob.new.handle(triage_id: triage.id)
    snap = ReportSnapshot.find_by!(triage_id: triage.id)
    expect(snap.payload).to have_key("recommendation")
    expect(snap.payload["recommendation"]).to be_nil
  end
end
