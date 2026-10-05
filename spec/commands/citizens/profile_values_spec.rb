require "rails_helper"

# Contratos §2: birth_date YYYY-MM-DD, não futura, idade ≤ 130; sex
# female|male; gender_identity da lista do e-SUS ou nulo.
RSpec.describe Citizens::ProfileValues do
  let(:today) { Date.new(2026, 10, 5) }

  def call(birth_date: "1963-04-02", sex: "female", gender_identity: nil)
    described_class.call(birth_date: birth_date, sex: sex, gender_identity: gender_identity, today: today)
  end

  it "normaliza um perfil válido" do
    expect(call.payload).to eq(birth_date: "1963-04-02", sex: "female", gender_identity: nil)
    expect(call(gender_identity: "travesti").payload[:gender_identity]).to eq("travesti")
    expect(call(gender_identity: "").payload[:gender_identity]).to be_nil
    expect(call(birth_date: "2026-10-05").payload[:birth_date]).to eq("2026-10-05")
    expect(call(birth_date: "1896-10-05")).to be_ok
  end

  it "recusa data inválida, futura ou de mais de 130 anos" do
    [ "2026-10-06", "1895-10-05", "1963-02-30", "02/04/1963", "1963-4-2", 19630402, nil, "" ].each do |value|
      expect(call(birth_date: value).reason).to eq(:invalid_birth_date), value.inspect
    end
  end

  it "recusa sexo e identidade de gênero fora da lista" do
    [ "F", "feminino", "other", nil, 1 ].each { |value| expect(call(sex: value).reason).to eq(:invalid_sex), value.inspect }
    [ "mulher", 1, [ "cis_woman" ] ].each do |value|
      expect(call(gender_identity: value).reason).to eq(:invalid_gender_identity), value.inspect
    end
  end
end
