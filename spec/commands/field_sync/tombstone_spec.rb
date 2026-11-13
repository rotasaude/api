require "rails_helper"

# Módulo 24b (contrato §1, §9.4, Q9): lápide `moved` quando domicílio ou
# cadastro individual do 24a sai da microárea. Gravada na transação de quem
# chama; saída do cadastro e domicílio inativo não geram lápide (Desvio 6).
RSpec.describe FieldSync::Tombstone, type: :model do
  before { registry_city! }

  let(:team) { registry_team!(care_unit!) }
  let(:area_one) { registry_micro_area!(code: "01", team: team) }
  let(:area_two) { registry_micro_area!(code: "02", team: team) }
  let(:nurse) { registry_nurse!(team.health_unit, team: team) }
  let(:household) { registry_household!(micro_area: area_one) }

  def stones = FieldSyncTombstone.order(:entity_type, :entity_id).to_a

  def move_household!(target, by: nurse)
    TerritoryRegistry::SaveHousehold.call(params: registry_household_params(household).merge("micro_area_id" => target.id, "version" => household.version),
                                          by: by, household: household)
  end

  def patch_registration!(registration, params)
    TerritoryRegistry::SaveRegistration.call(params: params.merge("version" => registration.version), by: nurse, registration: registration)
  end

  it "grava só acréscimo com reason moved" do
    described_class.moved!(entity_type: "household", entity_id: SecureRandom.uuid, micro_area_id: area_one.id)
    stone = FieldSyncTombstone.take
    expect(stone).to have_attributes(entity_type: "household", reason: "moved", micro_area_id: area_one.id)
    expect { stone.update!(reason: "erased") }.to raise_error(ActiveRecord::StatementInvalid)
  end

  it "domicílio movido de 01 para 02 grava tombstone household em 01 e registration dos moradores em 01" do
    first = registry_registration!(household: household)
    second = registry_registration!(household: household)
    expect(FieldSyncTombstone.count).to eq(0)
    expect(move_household!(area_two)).to be_ok
    expect(stones.map { |s| [ s.entity_type, s.entity_id, s.micro_area_id, s.reason ] }).to match_array(
      [ [ "household", household.id, area_one.id, "moved" ],
        [ "registration", first.id, area_one.id, "moved" ],
        [ "registration", second.id, area_one.id, "moved" ] ]
    )
  end

  it "domicílio novo e mudança dentro da microárea não gravam" do
    registration = registry_registration!(household: household)
    expect(FieldSyncTombstone.count).to eq(0)
    result = TerritoryRegistry::SaveHousehold.call(params: registry_household_params(household).merge("contact_phone" => "4133335555", "version" => household.version),
                                                   by: nurse, household: household)
    expect(result).to be_ok
    expect(registration.reload.version).to eq(1)
    expect(FieldSyncTombstone.count).to eq(0)
  end

  it "cadastro que muda para domicílio de outra microárea grava tombstone em 01" do
    registration = registry_registration!(household: household)
    other = registry_household!(micro_area: area_two)
    result = patch_registration!(registration, registry_registration_params(other, patient: registration.patient))
    expect(result).to be_ok
    expect(stones.map { |s| [ s.entity_type, s.entity_id, s.micro_area_id, s.reason ] }).to eq([ [ "registration", registration.id, area_one.id, "moved" ] ])
  end

  it "cadastro que passa a nenhum domicílio (micro_area_id diferente) grava tombstone em 01" do
    registration = registry_registration!(household: household)
    result = patch_registration!(registration, registry_registration_params(team, patient: registration.patient))
    expect(result).to be_ok
    expect(registration.reload.micro_area_id).to be_nil
    expect(stones.map { |s| [ s.entity_id, s.micro_area_id ] }).to eq([ [ registration.id, area_one.id ] ])
  end

  it "mudança de domicílio dentro da microárea não grava" do
    registration = registry_registration!(household: household)
    sibling = registry_household!(micro_area: area_one)
    result = patch_registration!(registration, registry_registration_params(sibling, patient: registration.patient))
    expect(result).to be_ok
    expect(registration.reload.household_id).to eq(sibling.id)
    expect(FieldSyncTombstone.count).to eq(0)
  end

  it "cadastro novo não grava" do
    registry_registration!(household: household)
    expect(FieldSyncTombstone.count).to eq(0)
  end

  it "saída por mudança ou óbito não grava" do
    gone = registry_registration!(household: household)
    dead = registry_registration!(household: household)
    acs = registry_acs_of(household)
    %w[moved death].each_with_index do |reason, index|
      registration = [ gone, dead ][index]
      result = TerritoryRegistry::ExitRegistration.call(registration: registration, params: exit_params(reason), by: acs)
      expect(result).to be_ok
    end
    expect(FieldSyncTombstone.count).to eq(0)
  end

  def exit_params(reason)
    today = Time.zone.today.iso8601
    reason == "death" ? { "reason" => reason, "on" => today, "death_on" => today } : { "reason" => reason, "on" => today }
  end

  it "domicílio inativado não grava" do
    result = TerritoryRegistry::SaveHousehold.call(params: registry_household_params(household).merge("status" => "inactive", "version" => household.version),
                                                   by: nurse, household: household)
    expect(result).to be_ok
    expect(household.reload.status).to eq("inactive")
    expect(FieldSyncTombstone.count).to eq(0)
  end

  it "recusa do SaveHousehold desfaz o tombstone" do
    registry_registration!(household: household)
    allow(Ledi::HouseholdRegistrationFicha).to receive(:generate).and_raise(TerritoryRegistry::SaveHousehold::Refused.new(Result.fail(:stale_version)))
    expect(move_household!(area_two).reason).to eq(:stale_version)
    expect(household.reload.micro_area_id).to eq(area_one.id)
    expect(FieldSyncTombstone.count).to eq(0)
  end

  it "recusa do SaveRegistration desfaz o tombstone" do
    registration = registry_registration!(household: household)
    other = registry_household!(micro_area: area_two)
    allow(Ledi::IndividualRegistrationFicha).to receive(:generate).and_raise(TerritoryRegistry::SaveRegistration::Refused.new(Result.fail(:stale_version)))
    expect(patch_registration!(registration, registry_registration_params(other, patient: registration.patient)).reason).to eq(:stale_version)
    expect(registration.reload.household_id).to eq(household.id)
    expect(FieldSyncTombstone.count).to eq(0)
  end
end
