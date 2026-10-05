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

  describe "com perfil (ADR 0027)" do
    let(:profile) { { birth_date: "1963-04-02", sex: "female", gender_identity: nil } }

    it "par novo nasce declared, com created: true e o evento" do
      result = described_class.call(phone: "+5541998765432", cpf: "529.982.247-25", profile: profile)
      expect(result.payload[:created]).to be(true)
      expect(result.payload[:citizen].reload).to have_attributes(birth_date: "1963-04-02", profile_source: "declared")
      expect(DomainEvent.where(name: "citizen.profile_changed").count).to eq(1)
    end

    it "par existente: created: false e perfil intacto" do
      Citizen.create!(cpf: "52998224725", phone: "+5541998765432")
      result = described_class.call(phone: "+5541998765432", cpf: "529.982.247-25", profile: profile)
      expect(result.payload[:created]).to be(false)
      expect(result.payload[:citizen].reload.profile_source).to be_nil
    end
  end
end
