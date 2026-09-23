require "rails_helper"

RSpec.describe Citizens::StepPayload do
  before do
    Current.city = TEST_CITY_A
    create_default_protocol!
  end
  after { Current.reset; Rails.cache.clear }

  let(:conversation) do
    Conversation.create!(phone: "+5541998765432", state: :awaiting_consent).tap do |c|
      GiveConsent.call(conversation: c, version: Consents.current_version, evidence: {})
    end
  end
  let(:triage) { StartTriage.call(conversation: conversation).payload[:triage] }

  it "descreve o passo atual com opções, progresso e voltar" do
    expect(described_class.for(triage)).to eq(
      triage_id: triage.id, step_id: "tosse", prompt: "Você está com tosse?", answer_type: "boolean",
      options: [{ id: "true", title: "Sim" }, { id: "false", title: "Não" }],
      index: 1, total: 2, can_undo: false
    )
  end

  it "no segundo passo, pode voltar" do
    CompleteTriage.call(triage: triage, answer: "true")
    payload = described_class.for(triage.reload)
    expect(payload).to include(step_id: "febre", index: 2, total: 2, can_undo: true)
  end

  it "enum mostra todas as opções, sem truncar" do
    step = Protocols::Step.new(id: "s", prompt: "?", answer_type: :enum,
                               options: ["Uma opção com um título bem maior que vinte e quatro letras"] + (1..11).map(&:to_s))
    expect(described_class.options_for(step).size).to eq(12)
    expect(described_class.options_for(step).first[:title]).to eq("Uma opção com um título bem maior que vinte e quatro letras")
  end
end
