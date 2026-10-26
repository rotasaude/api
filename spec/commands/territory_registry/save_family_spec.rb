require "rails_helper"

# Contrato §14 L28: a família nova leva junto o cadastro individual ATIVO do
# responsável NO MESMO domicílio — family_id e is_responsible true, numa versão
# nova (origin save, em nome de quem gravou a família, com o CBO dele) e
# ficha individual, na mesma transação (pacientes → domicílio → família →
# cadastro). Cadastro em outro domicílio, ou nenhum: nada muda.
RSpec.describe TerritoryRegistry::SaveFamily do
  before { registry_city! }

  def create_family(household, responsible, by: registry_acs_of(household))
    described_class.call(household: household, by: by,
                         params: { "responsible" => { "patient_id" => responsible.id }, "members_count" => 1, "version" => household.reload.version })
  end

  def join_family!(household, patient, family)
    params = registry_registration_params(household, patient: patient).merge("family_id" => family.id)
    params["sociodemographic"] = params["sociodemographic"].merge("relacao_parentesco_cidadao" => 137)
    result = TerritoryRegistry::SaveRegistration.call(params: params, by: registry_acs_of(household))
    raise "cadastro recusado: #{result.reason} #{result.details}" if result.failure?

    result.payload[:registration]
  end

  it "família nova: o cadastro do responsável no domicílio ganha family_id e is_responsible, uma versão e uma ficha" do
    household = registry_household!
    responsible = registry_patient!
    registration = registry_registration!(patient: responsible, household: household)
    neighbour = registry_registration!(household: household)
    acs = registry_acs_of(household)
    result = create_family(household, responsible, by: acs)
    expect(result).to be_ok
    family = result.payload[:family]
    registration.reload
    expect(registration).to have_attributes(family_id: family.id, is_responsible: true, version: 2, registered_by_user_id: acs.id)
    expect(registration.versions.count).to eq(2)
    latest = registration.latest_version
    expect(latest).to have_attributes(origin: "save", family_id: family.id, is_responsible: true, household_id: household.id,
                                      saved_by_user_id: acs.id, saved_cbo: TerritoryRegistry::Catalog::ACS_CBO)
    expect(latest.health_conditions).to eq(registration.versions.first.health_conditions)
    expect(LediOutboxEntry.where(source_id: latest.id, ficha_type: "cadastro_individual").count).to eq(1)
    expect(LediOutboxEntry.where(ficha_type: "cadastro_individual").count).to eq(3) # 2 cadastros + a versão nova
    expect(neighbour.reload).to have_attributes(version: 1, family_id: nil, is_responsible: false)
    expect(DomainEvent.where(name: "territory_registration.saved").where("payload->>'registration_version_id' = ?", latest.id).sole.payload)
      .to eq("registration_id" => registration.id, "registration_version_id" => latest.id, "patient_id" => responsible.id, "user_id" => acs.id)
  end

  it "membro de outra família do domicílio vira responsável de família nova: muda de família, sem parentesco" do
    household = registry_household!
    first = registry_family!(household)
    member = registry_patient!
    registration = join_family!(household, member, first)
    expect(registration).to have_attributes(family_id: first.id, is_responsible: false)
    result = create_family(household, member)
    expect(result).to be_ok
    latest = registration.reload.latest_version
    expect(registration).to have_attributes(family_id: result.payload[:family].id, is_responsible: true, version: 2)
    expect(registration.versions.order(:version).first.sociodemographic).to include("relacao_parentesco_cidadao" => 137)
    expect(latest.sociodemographic).not_to have_key("relacao_parentesco_cidadao")
    expect(LediOutboxEntry.where(source_id: latest.id, ficha_type: "cadastro_individual")).to exist
  end

  it "responsável cadastrado em outro domicílio, ou sem cadastro: nada muda no cadastro" do
    household = registry_household!
    elsewhere = registry_household!(micro_area: household.micro_area)
    responsible = registry_patient!
    registration = registry_registration!(patient: responsible, household: elsewhere)
    expect(create_family(household, responsible)).to be_ok
    expect(registration.reload).to have_attributes(version: 1, family_id: nil, is_responsible: false)
    expect(create_family(household, registry_patient!)).to be_ok
    expect(IndividualRegistrationVersion.count).to eq(1)
  end

  it "o responsável nunca muda: PATCH com outro responsável recusado e nenhum cadastro muda" do
    household = registry_household!
    family = registry_family!(household)
    other = registry_patient!
    registration = registry_registration!(patient: other, household: household)
    result = described_class.call(household: household, family: family, by: registry_acs_of(household),
                                  params: { "responsible" => { "patient_id" => other.id }, "members_count" => 1, "version" => household.reload.version })
    expect(result.reason).to eq(:invalid_family)
    expect(result.details).to eq(path: "responsible.patient_id")
    expect(registration.reload).to have_attributes(version: 1, family_id: nil, is_responsible: false)
  end

  it "recusa do domicílio depois da família (membros acima dos moradores) desfaz a versão do cadastro do responsável" do
    household = registry_household!
    responsible = registry_patient!
    registration = registry_registration!(patient: responsible, household: household)
    result = described_class.call(household: household, by: registry_acs_of(household),
                                  params: { "responsible" => { "patient_id" => responsible.id }, "members_count" => 9,
                                            "version" => household.reload.version })
    expect(result).to be_failure
    expect(registration.reload).to have_attributes(version: 1, family_id: nil, is_responsible: false)
    expect(registration.versions.count).to eq(1)
    expect(Family.count).to eq(0)
  end
end
