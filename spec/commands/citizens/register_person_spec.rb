require "rails_helper"

RSpec.describe Citizens::RegisterPerson do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:phone) { "+5541998765432" }

  it "cria o cidadão declarado com o CPF normalizado" do
    result = described_class.call(phone: phone, cpf: "529.982.247-25")
    expect(result.payload[:citizen].cpf).to eq("52998224725")
    expect(result.payload[:citizen]).to be_verification_level_declared
  end

  it "devolve o mesmo cidadão para o mesmo par" do
    first = described_class.call(phone: phone, cpf: "52998224725").payload[:citizen]
    expect(described_class.call(phone: phone, cpf: "529.982.247-25").payload[:citizen]).to eq(first)
  end

  it "recusa CPF inválido" do
    expect(described_class.call(phone: phone, cpf: "111.111.111-11").reason).to eq(:invalid_cpf)
  end

  # Monta um CPF válido a partir de 9 dígitos, com a mesma conta da produção.
  def valid_cpf(base)
    nums = base.chars.map(&:to_i)
    first = CitizenIdentity::Cpf.check_digit(nums)
    second = CitizenIdentity::Cpf.check_digit(nums + [first])
    "#{base}#{first}#{second}"
  end

  it "recusa o 11º CPF no mesmo telefone" do
    cpfs = (1..11).map { |i| valid_cpf(format("%09d", 100_000_000 + i * 7_919)) }
    cpfs.first(10).each { |cpf| expect(described_class.call(phone: phone, cpf: cpf)).to be_ok }
    expect(described_class.call(phone: phone, cpf: cpfs.last).reason).to eq(:too_many_people)
  end
end
