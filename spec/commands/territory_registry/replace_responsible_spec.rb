require "rails_helper"

# Contrato §14 L29 (PROVA-2): no LEDI trocar o responsável é família nova. A
# partir de um morador com cadastro ATIVO da família antiga, nasce a família
# nova com ele como responsável; os membros ativos passam para ela (versão
# nova do cadastro + ficha individual, sem relacao_parentesco_cidadao — a
# relação era com o responsável antigo); a antiga fica em mudança (moved_out,
# stMudanca na ficha). Tudo numa versão nova do domicílio + ficha domiciliar,
# em nome de quem gravou. Travas: pacientes → domicílio → família → cadastro.
RSpec.describe TerritoryRegistry::ReplaceResponsible do
  before { registry_city! }

  let(:household) { registry_household! }
  let(:acs) { registry_acs_of(household) }

  def join_family!(patient, family, kinship: 137)
    params = registry_registration_params(household, patient: patient).merge("family_id" => family.id)
    params["sociodemographic"] = params["sociodemographic"].merge("relacao_parentesco_cidadao" => kinship)
    result = TerritoryRegistry::SaveRegistration.call(params: params, by: acs)
    raise "cadastro recusado: #{result.reason} #{result.details}" if result.failure?

    result.payload[:registration]
  end

  def death!(registration)
    result = TerritoryRegistry::ExitRegistration.call(registration: registration, by: acs,
                                                      params: { "reason" => "death", "on" => Time.zone.today.iso8601,
                                                                "death_on" => Time.zone.today.iso8601 })
    raise "saída recusada: #{result.reason}" if result.failure?
  end

  def replace(family, patient, by: acs, version: household.reload.version)
    described_class.call(family: family, by: by, params: { "responsible" => { "patient_id" => patient.id }, "version" => version })
  end

  # Responsável A (com cadastro, ligado pela L28), membros B e C; A morre.
  def scenario!
    a = registry_patient!
    a_registration = registry_registration!(patient: a, household: household)
    family = registry_family!(household, responsible: a, "members_count" => 3, "income_band" => "2", "living_since" => "2019-03")
    b = registry_patient!
    c = registry_patient!
    b_registration = join_family!(b, family)
    c_registration = join_family!(c, family, kinship: 138)
    death!(a_registration.reload)
    { a: a, a_registration: a_registration.reload, family: family, b: b, b_registration: b_registration, c: c, c_registration: c_registration }
  end

  it "óbito do responsável → família nova com os membros, antiga em mudança; versões e fichas (individual em cascata + domiciliar)" do
    s = scenario!
    expect(TerritoryRegistry::Families.responsible_exited_ids([ s[:family] ])).to eq(Set[s[:family].id])
    before_version = household.reload.version
    domiciliar = LediOutboxEntry.where(ficha_type: "cadastro_domiciliar")
    individual = LediOutboxEntry.where(ficha_type: "cadastro_individual")

    result = nil
    expect { result = replace(s[:family], s[:b]) }.to change(domiciliar, :count).by(1).and change(individual, :count).by(2)
    expect(result).to be_ok
    fresh = result.payload[:family]
    # Revisão m3: quem saiu (A, óbito) não conta na família nova: 3 − 1.
    expect(fresh).to have_attributes(household_id: household.id, responsible_patient_id: s[:b].id, moved_out: false, members_count: 2,
                                     income_band: "2", living_since: "2019-03")
    expect(s[:family].reload.moved_out).to be(true)
    expect(household.reload.version).to eq(before_version + 1)
    snapshot = household.latest_version.families_snapshot
    expect(snapshot.map { |row| row.slice("family_id", "moved_out", "responsible_exited") })
      .to eq([ { "family_id" => s[:family].id, "moved_out" => true, "responsible_exited" => false },
               { "family_id" => fresh.id, "moved_out" => false, "responsible_exited" => false } ])
    expect(household.latest_version).to have_attributes(saved_by_user_id: acs.id, saved_cbo: TerritoryRegistry::Catalog::ACS_CBO)

    b = s[:b_registration].reload
    expect(b).to have_attributes(family_id: fresh.id, is_responsible: true, version: 2, registered_by_user_id: acs.id)
    expect(b.latest_version).to have_attributes(origin: "save", family_id: fresh.id, is_responsible: true, saved_by_user_id: acs.id)
    expect(b.latest_version.sociodemographic).not_to have_key("relacao_parentesco_cidadao")
    c = s[:c_registration].reload
    expect(c).to have_attributes(family_id: fresh.id, is_responsible: false, version: 2)
    expect(c.latest_version.sociodemographic).not_to have_key("relacao_parentesco_cidadao")
    expect(c.versions.first.sociodemographic).to include("relacao_parentesco_cidadao" => 138)
    expect(s[:a_registration].reload).to have_attributes(exit_reason: "death", family_id: s[:family].id, version: 3)
    [ b, c ].each do |registration|
      expect(LediOutboxEntry.where(source_id: registration.latest_version.id, ficha_type: "cadastro_individual")).to exist
    end

    event = DomainEvent.where(name: "family.responsible_replaced").sole
    expect(event.payload).to eq("household_id" => household.id, "family_id" => s[:family].id, "new_family_id" => fresh.id, "user_id" => acs.id)
    expect(DomainEvent.where(name: "household.saved").order(:created_at).last.payload)
      .to include("household_id" => household.id, "household_version_id" => household.latest_version.id)
    # A ficha domiciliar da troca: a família antiga em mudança, a nova com o responsável novo.
    entry = LediOutboxEntry.find_by!(source_type: "HouseholdVersion", source_id: household.latest_version.id)
    rows = Ledi::Version.deserialize(Ledi::FichaTypes.klass("cadastro_domiciliar"), Ledi::Transport.read(entry.bytes).dadoSerializado).familias
    expect(rows.map { |row| [ row.cpfResponsavel, row.stMudanca ] }).to eq([ [ s[:a].cpf, true ], [ s[:b].cpf, false ] ])
    expect(TerritoryRegistry::Families.responsible_exited_ids(Family.where(household: household).to_a)).to be_empty
  end

  it "troca com o responsável vivo: ele vira membro da família nova (sem parentesco); ninguém saiu, os membros ficam" do
    a = registry_patient!
    a_registration = registry_registration!(patient: a, household: household)
    family = registry_family!(household, responsible: a, "members_count" => 2)
    b = registry_patient!
    join_family!(b, family)
    result = replace(family, b)
    expect(result).to be_ok
    expect(result.payload[:family].members_count).to eq(2)
    expect(a_registration.reload).to have_attributes(family_id: result.payload[:family].id, is_responsible: false)
  end

  # Revisão m3: members_count da nova = o da antiga menos os membros cujo
  # cadastro na família saiu (óbito ou mudança), com piso 1; sem o campo, sem.
  it "família nova: desconta quem saiu, com piso 1; antiga sem members_count → nova sem" do
    s = scenario!
    death!(s[:c_registration].reload)
    s[:family].update_columns(members_count: 2)
    expect(replace(s[:family], s[:b]).payload[:family].members_count).to eq(1) # 2 − 2 (A e C) → piso 1

    other = registry_household!(micro_area: household.micro_area)
    x = registry_patient!
    registry_registration!(patient: x, household: other)
    family = registry_family!(other, responsible: x)
    family.update_columns(members_count: nil)
    y = registry_patient!
    params = registry_registration_params(other, patient: y).merge("family_id" => family.id)
    expect(TerritoryRegistry::SaveRegistration.call(params: params, by: acs)).to be_ok
    result = described_class.call(family: family, by: acs, params: { "responsible" => { "patient_id" => y.id }, "version" => other.reload.version })
    expect(result.payload[:family].members_count).to be_nil
  end

  it "recusas: quem não é membro ativo da família, o próprio responsável, família em mudança, versão velha; nada muda" do
    s = scenario!
    outsider = registry_patient!
    registry_registration!(patient: outsider, household: household)
    expect(replace(s[:family], outsider).to_h).to include(reason: :invalid_family, details: { path: "responsible.patient_id" })
    expect(replace(s[:family], s[:a]).to_h).to include(reason: :invalid_family, details: { path: "responsible.patient_id" })
    expect(replace(s[:family], s[:b], version: household.reload.version - 1).reason).to eq(:stale_version)
    bad = described_class.call(family: s[:family], by: acs, params: { "responsible" => { "patient_id" => s[:b].id }, "version" => "1" })
    expect(bad.to_h).to include(reason: :invalid_family, details: { path: "version" })
    expect(Family.count).to eq(1)
    expect(s[:b_registration].reload.version).to eq(1)

    expect(TerritoryRegistry::SaveFamily.call(household: household, family: s[:family], by: acs,
                                              params: { "moved_out" => true, "version" => household.reload.version })).to be_ok
    expect(replace(s[:family].reload, s[:b]).to_h).to include(reason: :invalid_family, details: { path: "moved_out" })
  end

  it "escopo de quem grava a ficha domiciliar: ACS de outra microárea → out_of_scope; nada muda" do
    s = scenario!
    other = registry_acs!(household.micro_area.team.health_unit, team: household.micro_area.team)
    registry_micro_area!(code: "02", team: household.micro_area.team, acs: other)
    expect(replace(s[:family], s[:b], by: other).reason).to eq(:out_of_scope)
    expect(s[:family].reload.moved_out).to be(false)
    expect(Family.count).to eq(1)
  end

  # Revisão m6: o CBO de quem grava precisa estar também na Tabela 1 (a
  # cascata gera fichas individuais). Nas tabelas atuais todo CBO de cadastro
  # da Tabela 2 está na 1; a Tabela 1 sem o CBO do ACS prova o ramo.
  it "CBO fora da Tabela 1 (ficha individual da cascata) → cbo_not_allowed; nada muda" do
    s = scenario!
    tables = TerritoryRegistry::Access::REGISTRATION_CBOS
    stub_const("TerritoryRegistry::Access::REGISTRATION_CBOS",
               tables.merge(individual: (tables[:individual] - [ TerritoryRegistry::Catalog::ACS_CBO ]).freeze))
    expect(replace(s[:family], s[:b]).reason).to eq(:cbo_not_allowed)
    expect(s[:family].reload.moved_out).to be(false)
    expect(s[:b_registration].reload.version).to eq(1)
    expect(Family.count).to eq(1)
  end

  it "o trigger families_guard segue recusando trocar o responsável na própria família" do
    s = scenario!
    expect { s[:family].update_columns(responsible_patient_id: s[:b].id) }
      .to raise_error(ActiveRecord::StatementInvalid, /household and responsible never change/)
  end
end
