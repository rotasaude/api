require "rails_helper"

RSpec.describe Citizens::RevokeVerification do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:verifier) { User.create!(email_address: "atendente@cidade.gov.br", password: "senha-segura-123") }
  let(:admin) { User.create!(email_address: "admin@cidade.gov.br", password: "senha-segura-123") }
  let(:verification) do
    Citizens::Verify.call(cpf: citizen.cpf, code: issue_code_for(citizen), document_checked: true, by: verifier)
                    .payload[:verification]
  end

  it "desfaz, volta o par a declared e publica o evento" do
    result = described_class.call(verification: verification, reason: "documento de outra pessoa", by: admin)
    expect(result).to be_ok
    expect(citizen.reload).to be_verification_level_declared
    expect(DomainEvent.where(name: "citizen.verification_revoked").sole.payload)
      .to include("citizen_id" => citizen.id, "revoked_by_user_id" => admin.id)
  end

  it "o validador não desfaz a própria validação" do
    expect(described_class.call(verification: verification, reason: "documento de outra pessoa", by: verifier).reason)
      .to eq(:own_verification)
  end

  it "motivo curto é recusado" do
    expect(described_class.call(verification: verification, reason: "  curto  ", by: admin).reason).to eq(:reason_too_short)
  end

  it "desfazer duas vezes é recusado" do
    described_class.call(verification: verification, reason: "documento de outra pessoa", by: admin)
    expect(described_class.call(verification: verification.reload, reason: "de novo, por engano", by: admin).reason)
      .to eq(:already_revoked)
  end

  it "depois de desfeita, o par pode ser validado de novo" do
    described_class.call(verification: verification, reason: "documento de outra pessoa", by: admin)
    again = Citizens::Verify.call(cpf: citizen.cpf, code: issue_code_for(citizen), document_checked: true, by: verifier)
    expect(again).to be_ok
    expect(CitizenVerification.where(citizen: citizen).count).to eq(2)
  end
end
