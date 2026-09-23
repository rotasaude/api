require "rails_helper"

RSpec.describe UndoLastAnswer do
  before do
    Current.city = TEST_CITY_A
    create_default_protocol!
    GiveConsent.call(conversation: conversation, version: Consents.current_version, evidence: {})
  end
  after { Current.reset; Rails.cache.clear }

  let(:conversation) { Conversation.create!(phone: "+5541998765432", state: :awaiting_consent) }
  let(:triage) { StartTriage.call(conversation: conversation).payload[:triage] }

  it "tira a última resposta e volta ao passo dela" do
    CompleteTriage.call(triage: triage, answer: "true")
    expect(triage.reload.current_step).to eq("febre")

    result = described_class.call(triage: triage)
    expect(result).to be_ok
    expect(triage.reload.answers).to eq({})
    expect(triage.current_step).to eq("tosse")
  end

  it "desfazer e responder de novo a mesma coisa leva ao mesmo estado" do
    CompleteTriage.call(triage: triage, answer: "true")
    before_undo = triage.reload.attributes.slice("answers", "current_step", "status")
    described_class.call(triage: triage)
    CompleteTriage.call(triage: triage.reload, answer: "true")
    expect(triage.reload.attributes.slice("answers", "current_step", "status")).to eq(before_undo)
  end

  it "recusa sem resposta a desfazer" do
    expect(described_class.call(triage: triage).reason).to eq(:nothing_to_undo)
  end

  it "recusa depois da triagem concluída" do
    CompleteTriage.call(triage: triage, answer: "true")
    CompleteTriage.call(triage: triage.reload, answer: "true")
    expect(triage.reload).to be_status_completed
    expect(described_class.call(triage: triage).reason).to eq(:not_in_progress)
    expect(triage.reload.answers).to eq("tosse" => "true", "febre" => "true")
  end
end
