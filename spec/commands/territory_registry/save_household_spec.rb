require "rails_helper"

# Módulo 24a (ADR 0042; plano, Desvios 8, 9 e 12): a gravação do domicílio
# regrava o endereço dos moradores com cadastro ativo; a recepção e o
# faturamento deixam de editá-lo; inativo só sem famílias ativas.
RSpec.describe TerritoryRegistry::SaveHousehold do
  before { registry_city! }

  it "endereço do domicílio vai para os moradores com cadastro ativo; o faturamento não o edita mais" do
    household = registry_household!
    registration = registry_registration!(household: household)
    patient = registration.patient
    outsider = registry_patient!
    result = described_class.call(params: registry_household_params(household).deep_merge("address" => { "street" => "Rua Nova", "number" => "", "no_number" => true },
                                                                                          "version" => household.version),
                                  by: registry_acs_of(household), household: household)
    expect(result).to be_ok
    expect(result.payload[:version].version).to eq(2)
    expect(patient.reload.address_street).to eq("Rua Nova")
    expect(patient).to have_attributes(address_number: "SN", address_zip: "80010000", address_district: "Centro", address_complement: nil)
    expect(outsider.reload.address_street).to be_nil
    result = ApplicationRecord.transaction { patient.lock!; Patients::Demographics.save!(patient, "address_street" => "Outra") }
    expect(result.reason).to eq(:address_from_household)
    expect(result.details).to eq(field: "address_street")
    expect(patient.reload.address_street).to eq("Rua Nova")
    expect(Patients::Demographics.flags(patient)).to include(address_from_household: true)
    expect(Patients::Demographics.flags(outsider)).to include(address_from_household: false)
    expect(Patients::Demographics.save!(patient, "race_color" => "02")).to be_ok
  end

  it "domicílio inativo só sem famílias ativas" do
    household = registry_household!
    registry_family!(household)
    result = described_class.call(params: registry_household_params(household).merge("status" => "inactive", "version" => household.version),
                                  by: registry_acs_of(household), household: household)
    expect(result.reason).to eq(:invalid_household)
    expect(result.details[:path]).to eq("status")
    expect(household.reload.status).to eq("active")
  end

  it "o retrato das famílias vai na versão; a recusa da regra devolve o path e nada grava" do
    household = registry_household!
    family = registry_family!(household, responsible: registry_patient!)
    version = household.reload.latest_version
    expect(version.version).to eq(2)
    expect(version.families_snapshot).to eq([ { "family_id" => family.id, "responsible_patient_id" => family.responsible_patient_id,
                                                "income_band" => nil, "members_count" => 1, "living_since" => nil, "moved_out" => false } ])
    params = registry_household_params(household).merge("property_type" => "2", "living_conditions" => nil, "version" => 2)
    result = described_class.call(params: params, by: registry_acs_of(household), household: household)
    expect(result.details).to eq(path: "families")
    expect(household.reload.version).to eq(2)
  end
end
