require "rails_helper"

RSpec.describe Citizens::LookupForVerification do
  before do
    Current.city = TEST_CITY_A
    create_default_protocol!
  end
  after { Current.reset; Rails.cache.clear }

  let(:mine) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:family) { Citizen.create!(cpf: "52998224725", phone: "+5541911112222") }

  def triage_for(citizen)
    started = Citizens::StartConversation.call(citizen: citizen, consent_version: Consents.current_version, session_id: "s").payload
    Citizens::SubmitAnswer.call(conversation: started[:conversation], answer: "false", idempotency_key: SecureRandom.uuid)
  end

  it "devolve o par do código e só data + protocolo das triagens de todos os pares do CPF" do
    triage_for(mine)
    triage_for(family)
    result = described_class.call(cpf: mine.cpf, code: issue_code_for(mine))
    expect(result.payload[:citizen]).to eq(mine)
    expect(result.payload[:triages].size).to eq(2)
    expect(result.payload[:triages].first.keys).to contain_exactly(:date, :protocol_name)
    expect(result.payload[:triages].map { |t| t[:protocol_name] }.uniq).to eq([StartTriage::DEFAULT_PROTOCOL_NAME])
  end

  it "sem código certo, nada volta" do
    expect(described_class.call(cpf: mine.cpf, code: "").payload).to eq({})
  end
end
