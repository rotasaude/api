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

  # Ruling da Task 9 (aplicado na Task 10): o domicílio que muda de
  # microárea leva junto os cadastros individuais ATIVOS dos moradores —
  # versão nova (origin save, em nome de quem gravou o domicílio, com o CBO
  # dele) e ficha individual; quem saiu (ou cuja família mudou e saiu) não.
  it "troca de microárea: os 2 moradores ativos ganham versão e ficha com a microárea e a equipe novas; quem saiu, nada" do
    household = registry_household!
    original_area_id = household.micro_area_id
    stay = registry_registration!(household: household)
    also = registry_registration!(household: household)
    gone = registry_registration!(household: household)
    acs = registry_acs_of(household)
    TerritoryRegistry::ExitRegistration.call(registration: gone, params: { "reason" => "moved", "on" => Time.zone.today.iso8601 }, by: acs)
    other_team = registry_team!(care_unit!)
    target = registry_micro_area!(code: "07", team: other_team)
    nurse = registry_nurse!(other_team.health_unit, team: other_team)
    result = described_class.call(params: registry_household_params(household).merge("micro_area_id" => target.id, "version" => household.version),
                                  by: nurse, household: household)
    expect(result).to be_ok
    [ stay, also ].each do |registration|
      registration.reload
      latest = registration.latest_version
      expect(registration).to have_attributes(version: 2, micro_area_id: target.id, team_id: other_team.id, registered_by_user_id: nurse.id)
      expect(latest).to have_attributes(origin: "save", micro_area_id: target.id, team_id: other_team.id, saved_by_user_id: nurse.id,
                                        saved_cbo: "223505", household_id: household.id)
      expect(latest.health_conditions).to eq(registration.versions.first.health_conditions)
      expect(LediOutboxEntry.where(source_id: latest.id, ficha_type: "cadastro_individual")).to exist
    end
    expect(gone.reload).to have_attributes(version: 2, micro_area_id: original_area_id)
    expect(gone.versions.count).to eq(2)
    expect(DomainEvent.where(name: "territory_registration.saved").where("payload->>'user_id' = ?", nurse.id).count).to eq(2)
  end

  it "mesma microárea: os cadastros dos moradores não mudam" do
    household = registry_household!
    registration = registry_registration!(household: household)
    described_class.call(params: registry_household_params(household).merge("contact_phone" => "4133335555", "version" => household.version),
                         by: registry_acs_of(household), household: household)
    expect(registration.reload.version).to eq(1)
  end

  # Desvio 12 (fix round 1): os moradores são relidos depois das travas; o
  # endereço só vai para quem ainda mora (quem saiu entre a leitura e a trava
  # pode já ter o endereço do domicílio novo); conjunto que cresce recomeça.
  context "moradores mudam entre a leitura e a trava" do
    let(:household) { registry_household! }
    let(:stay) { registry_registration!(household: household).patient }
    let(:other) { registry_registration!(household: household).patient }

    def save!
      params = registry_household_params(household).deep_merge("address" => { "street" => "Rua Nova" }, "version" => household.version)
      described_class.call(params: params, by: registry_acs_of(household), household: household)
    end

    it "quem saiu depois da leitura não recebe o endereço" do
      allow(described_class).to receive(:resident_ids).and_return([ stay.id, other.id ], [ stay.id ])
      expect(save!).to be_ok
      expect(stay.reload.address_street).to eq("Rua Nova")
      # o endereço que recebeu ao entrar (SaveRegistration), não o novo
      expect(other.reload.address_street).to eq("Rua das Flores")
    end

    it "conjunto que cresceu uma vez: recomeça e grava para todos" do
      allow(described_class).to receive(:resident_ids).and_return([ stay.id ], [ stay.id, other.id ], [ stay.id, other.id ])
      result = save!
      expect(result).to be_ok
      expect(described_class).to have_received(:resident_ids).exactly(4).times
      expect([ stay.reload.address_street, other.reload.address_street ]).to eq([ "Rua Nova", "Rua Nova" ])
      expect(household.reload.version).to eq(2)
      expect(HouseholdVersion.where(household_id: household.id).count).to eq(2)
    end

    it "conjunto que cresce sempre: desiste na terceira tentativa com stale_version (nunca 500), nada gravado" do
      allow(described_class).to receive(:resident_ids).and_return([], [ stay.id ], [], [ stay.id ], [], [ stay.id ])
      expect(save!.reason).to eq(:stale_version)
      expect(household.reload.version).to eq(1)
      expect(stay.reload.address_street).to eq("Rua das Flores")
    end
  end
end
