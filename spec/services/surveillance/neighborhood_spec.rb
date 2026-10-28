require "rails_helper"

RSpec.describe Surveillance::Neighborhood do
  include ActiveSupport::Testing::TimeHelpers
  before { registry_city! }
  let(:patient) { surveillance_patient!(21) }
  let(:pair_neighborhood) { Neighborhood.create!(name: "Boqueirão #{SecureRandom.hex(2)}", source: "manual") }
  let(:home_neighborhood) { Neighborhood.create!(name: "Cajuru #{SecureRandom.hex(2)}", source: "manual") }

  def pair = Citizen.find_by!(patient_id: patient.id)

  it "o bairro da última versão do domicílio do cadastro ativo vence o bairro do par" do
    pair.update!(neighborhood: pair_neighborhood)
    household = registry_household!(neighborhood: nil)
    registry_registration!(patient: patient, household: household)
    expect(described_class.for(patient)).to eq(pair_neighborhood.id) # domicílio sem bairro: cai no par
    registry_new_household_version!(household, neighborhood_id: home_neighborhood.id)
    expect(described_class.for(patient)).to eq(home_neighborhood.id)
  end

  it "cadastro que saiu não conta: vale o par" do
    pair.update!(neighborhood: pair_neighborhood)
    registration = registry_registration!(patient: patient, household: registry_household!(neighborhood: home_neighborhood))
    expect(described_class.for(patient)).to eq(home_neighborhood.id)
    registration.update_columns(exit_reason: "moved", exited_on: Time.zone.today)
    expect(described_class.for(patient)).to eq(pair_neighborhood.id)
  end

  it "sem cadastro: o bairro do par validado mais recente" do
    older = pair
    older.update!(neighborhood: pair_neighborhood)
    newer = verified_citizen!(22)
    newer.update!(cpf: older.cpf)
    Patients::Resolve.call(newer)
    travel_to(1.minute.from_now) { newer.reload.update!(neighborhood: home_neighborhood) }
    expect(newer.patient_id).to eq(patient.id)
    expect(described_class.for(patient)).to eq(home_neighborhood.id)
  end

  it "sem cadastro nem bairro no par: nil" do
    expect(described_class.for(patient)).to be_nil
  end
end
