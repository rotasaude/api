require "rails_helper"

RSpec.describe Citizen do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  it "nasce declarado e acha pelo CPF e telefone cifrados" do
    citizen = described_class.create!(cpf: "52998224725", phone: "+5541998765432")
    expect(citizen).to be_verification_level_declared
    expect(described_class.find_by(cpf: "52998224725", phone: "+5541998765432")).to eq(citizen)
    raw = described_class.connection.select_value("SELECT cpf FROM citizens WHERE id = '#{citizen.id}'")
    expect(raw).not_to include("52998224725")
  end

  it "não repete o par (CPF, telefone), mas aceita o mesmo CPF em outro telefone" do
    described_class.create!(cpf: "52998224725", phone: "+5541998765432")
    expect { described_class.create!(cpf: "52998224725", phone: "+5541998765432") }
      .to raise_error(ActiveRecord::RecordNotUnique)
    expect { described_class.create!(cpf: "52998224725", phone: "+5541911112222") }.not_to raise_error
  end

  it "mascara o CPF" do
    expect(described_class.new(cpf: "52998224725").cpf_masked).to eq("***.982.247-**")
  end
end
