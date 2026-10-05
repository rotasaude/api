require "rails_helper"

# ADR 0027 (spec 2026-10-05 §5.4): no padrão de SetNeighborhood — lock, evento
# só com o id, só quando muda; perfil verified não muda pelo cidadão.
RSpec.describe Citizens::SetProfile do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  def payloads = DomainEvent.where(name: "citizen.profile_changed").map(&:payload)

  def set(birth_date: "1963-04-02", sex: "female", gender_identity: nil, target: citizen)
    described_class.call(citizen: target, birth_date: birth_date, sex: sex, gender_identity: gender_identity)
  end

  it "grava declared e publica só o id" do
    expect(set(gender_identity: "cis_woman")).to be_ok
    expect(citizen.reload).to have_attributes(birth_date: "1963-04-02", sex: "female", gender_identity: "cis_woman",
                                              profile_source: "declared")
    expect(payloads).to eq([ { "citizen_id" => citizen.id } ])
  end

  it "corrige enquanto declared; repetir o mesmo valor não publica de novo" do
    set
    set
    set(sex: "male")
    expect(citizen.reload.sex).to eq("male")
    expect(payloads.size).to eq(2)
  end

  it "verified não muda pelo cidadão: :profile_verified e nada gravado" do
    citizen.update!(birth_date: "1963-04-02", sex: "female", profile_source: "verified")
    expect(set(birth_date: "1970-01-01").reason).to eq(:profile_verified)
    expect(citizen.reload).to have_attributes(birth_date: "1963-04-02", profile_source: "verified")
    expect(payloads).to be_empty
  end

  it "valor inválido: motivo de ProfileValues e nada gravado" do
    expect(set(sex: "x").reason).to eq(:invalid_sex)
    expect(citizen.reload.profile_source).to be_nil
  end
end
