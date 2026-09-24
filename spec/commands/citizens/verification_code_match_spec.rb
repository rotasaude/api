require "rails_helper"

RSpec.describe Citizens::VerificationCodeMatch do
  include ActiveSupport::Testing::TimeHelpers

  before { Current.city = TEST_CITY_A }
  after { Current.reset; travel_back }

  let(:mine) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:family) { Citizen.create!(cpf: "52998224725", phone: "+5541911112222") }
  let(:stranger) { Citizen.create!(cpf: "11144477735", phone: "+5541933334444") }

  def wrong(code) = code == "000000" ? "111111" : "000000"

  it "identifica o par dono do código, mesmo com outro par do CPF com código ativo" do
    issue_code_for(family)
    code = issue_code_for(mine)
    result = described_class.call(cpf: "529.982.247-25", code: code)
    expect(result.payload[:citizen]).to eq(mine)
  end

  it "código de outro CPF responde igual a código errado" do
    issue_code_for(mine)
    other = issue_code_for(stranger)
    expect(described_class.call(cpf: mine.cpf, code: other).reason).to eq(:invalid_code)
  end

  it "CPF sem código nenhum responde invalid_code" do
    expect(described_class.call(cpf: mine.cpf, code: "123456").reason).to eq(:invalid_code)
  end

  it "CPF inválido" do
    expect(described_class.call(cpf: "111.111.111-11", code: "123456").reason).to eq(:invalid_cpf)
  end

  it "vence em 10 minutos" do
    code = issue_code_for(mine)
    travel 11.minutes
    expect(described_class.call(cpf: mine.cpf, code: code).reason).to eq(:code_expired)
  end

  it "esgota em 5 tentativas erradas, mesmo que depois venha o código certo" do
    code = issue_code_for(mine)
    5.times { expect(described_class.call(cpf: mine.cpf, code: wrong(code)).reason).to eq(:invalid_code) }
    expect(described_class.call(cpf: mine.cpf, code: code).reason).to eq(:code_exhausted)
  end

  it "não consome o código (quem consome é a validação)" do
    code = issue_code_for(mine)
    2.times { expect(described_class.call(cpf: mine.cpf, code: code)).to be_ok }
  end

  it "código já consumido responde code_expired" do
    code = issue_code_for(mine)
    described_class.call(cpf: mine.cpf, code: code).payload[:verification_code].update!(consumed_at: Time.current)
    expect(described_class.call(cpf: mine.cpf, code: code).reason).to eq(:code_expired)
  end

  it "código em branco não identifica ninguém" do
    issue_code_for(mine)
    expect(described_class.call(cpf: mine.cpf, code: "").reason).to eq(:invalid_code)
  end
end
