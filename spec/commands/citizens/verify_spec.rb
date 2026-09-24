require "rails_helper"

RSpec.describe Citizens::Verify do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:verifier) { User.create!(email_address: "atendente@cidade.gov.br", password: "senha-segura-123") }

  def verify(code, checked: true)
    described_class.call(cpf: "529.982.247-25", code: code, document_checked: checked, by: verifier)
  end

  it "valida o par, consome o código, atualiza o nível e publica o evento" do
    code = issue_code_for(citizen)
    result = verify(code)
    expect(result).to be_ok
    expect(citizen.reload).to be_verification_level_verified
    expect(result.payload[:verification].verified_by_user).to eq(verifier)
    expect(CitizenVerificationCode.usable.where(citizen: citizen)).to be_empty
    event = DomainEvent.where(name: "citizen.verified").sole
    expect(event.payload).to eq("citizen_id" => citizen.id, "verification_id" => result.payload[:verification].id,
                                "verified_by_user_id" => verifier.id)
  end

  it "exige a caixa 'conferi o documento'" do
    code = issue_code_for(citizen)
    expect(verify(code, checked: false).reason).to eq(:document_check_required)
    expect(citizen.reload).to be_verification_level_declared
  end

  it "o mesmo código usado duas vezes: só a primeira valida" do
    code = issue_code_for(citizen)
    expect(verify(code)).to be_ok
    expect(verify(code).reason).to eq(:code_expired)
    expect(CitizenVerification.where(citizen: citizen).count).to eq(1)
  end

  it "esgota em 5 tentativas erradas dentro do próprio Verify, mesmo saindo da transação via next" do
    code = issue_code_for(citizen)
    wrong = code == "000000" ? "111111" : "000000"
    5.times { expect(verify(wrong).reason).to eq(:invalid_code) }
    expect(verify(code).reason).to eq(:code_exhausted)
  end

  it "não mexe em triagens, consentimentos nem métricas" do
    create_default_protocol!
    started = Citizens::StartConversation.call(citizen: citizen, consent_version: Consents.current_version, session_id: "s").payload
    Citizens::SubmitAnswer.call(conversation: started[:conversation], answer: "false", idempotency_key: "k")
    snapshot = -> { [Triage.order(:id).map(&:attributes), Consent.order(:id).map(&:attributes), DashboardMetric.order(:id).map(&:attributes)] }
    before = snapshot.call
    verify(issue_code_for(citizen))
    expect(snapshot.call).to eq(before)
  end
end
