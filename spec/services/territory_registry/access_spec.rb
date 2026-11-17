require "rails_helper"

# Módulo 24a (ADR 0042; contrato §1; plano, Desvio 4): quem grava ficha de
# cadastro. Membro ativo da equipe; enfermeiro/médico (2235*, 2251*, 2252*,
# 2253*) em qualquer microárea; ACS (515105) só na sua; e o CBO do vínculo na
# equipe precisa estar na Tabela 1 (individual) ou 2 (domiciliar) do LEDI.
RSpec.describe TerritoryRegistry::Access do
  before { registry_city! }

  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }
  let(:acs) { registry_acs!(unit, team: team) }
  let(:nurse) { registry_nurse!(unit, team: team) }
  let(:area) { registry_micro_area!(code: "01", team: team, acs: acs) }
  let(:other_area) { registry_micro_area!(code: "02", team: team) }

  def member_with(cbo)
    nurse.tap { HealthTeamMember.find_by!(professional: _1.professional, health_team: team).update!(cbo_code: cbo) }
  end

  it "admin? = municipal_admin" do
    expect(described_class.admin?(care_admin!)).to be(true)
    expect(described_class.admin?(nurse)).to be(false)
  end

  it "membership: vínculo ativo na equipe, com perfil e papel health_professional" do
    expect(described_class.membership(nurse, team)).to have_attributes(health_team_id: team.id, cbo_code: "223505")
    expect(described_class.membership(nurse, registry_team!(care_unit!))).to be_nil
    expect(described_class.membership(care_admin!, team)).to be_nil
    expect(described_class.membership(nurse, nil)).to be_nil
    nurse.memberships.where(role: "health_professional").update_all(revoked_at: Time.current)
    expect(described_class.membership(nurse, team)).to be_nil
  end

  it "membership: vínculo encerrado não conta" do
    HealthTeamMember.find_by!(professional: nurse.professional, health_team: team).update!(ended_on: Time.zone.today)
    expect(described_class.membership(nurse, team)).to be_nil
  end

  it "registrar_cbo?: Tabela 1 (individual) e Tabela 2 (domiciliar) da config; ficha desconhecida levanta" do
    tables = YAML.load_file(Rails.root.join("config/ledi/registration_cbos.yml"))
    only_individual = (tables["individual"] - tables["household"]).first
    expect(only_individual).to be_present
    expect(described_class.registrar_cbo?("515105", ficha: :individual)).to be(true)
    expect(described_class.registrar_cbo?("515105", ficha: :household)).to be(true)
    expect(described_class.registrar_cbo?(only_individual, ficha: :individual)).to be(true)
    expect(described_class.registrar_cbo?(only_individual, ficha: :household)).to be(false)
    expect(described_class.registrar_cbo?("225151", ficha: :individual)).to be(false) # fora das duas tabelas
    expect(described_class.registrar_cbo?("225151", ficha: :household)).to be(false)
    expect(described_class.registrar_cbo?(nil, ficha: :individual)).to be(false)
    expect { described_class.registrar_cbo?("515105", ficha: :visita) }.to raise_error(KeyError)
  end

  # Módulo 24b (ADR 0052; W-3): visita = Tabela 7 e atividade coletiva = Tabela 5,
  # pela mesma config, sem código novo.
  it "registrar_cbo? aceita :home_visit (515105, 322255) e :collective_activity (2231F9), e recusa 225125 em :home_visit" do
    expect(described_class.registrar_cbo?("515105", ficha: :home_visit)).to be(true)
    expect(described_class.registrar_cbo?("322255", ficha: :home_visit)).to be(true)
    expect(described_class.registrar_cbo?("225125", ficha: :home_visit)).to be(false)
    expect(described_class.registrar_cbo?("2231F9", ficha: :collective_activity)).to be(true)
    expect(described_class.registrar_cbo?("225125", ficha: :collective_activity)).to be(true)
    expect(described_class.registrar_cbo?("225151", ficha: :collective_activity)).to be(false)
  end

  it "registrar?: enfermeiro em qualquer microárea da equipe; ACS só na sua; equipe de fora → out_of_scope" do
    expect(described_class.registrar?(nurse, team, micro_area: area, ficha: :individual)).to eq(:ok)
    expect(described_class.registrar?(nurse, team, micro_area: other_area, ficha: :household)).to eq(:ok)
    expect(described_class.registrar?(nurse, team, ficha: :individual)).to eq(:ok)
    expect(described_class.registrar?(acs, team, micro_area: area, ficha: :household)).to eq(:ok)
    expect(described_class.registrar?(acs, team, micro_area: other_area, ficha: :household)).to eq(:out_of_scope)
    expect(described_class.registrar?(registry_acs!(care_unit!), team, micro_area: area, ficha: :individual)).to eq(:out_of_scope)
    expect(described_class.registrar?(care_admin!, team, micro_area: area, ficha: :individual)).to eq(:out_of_scope)
  end

  it "registrar?: ACS sem microárea (cadastro fora de área, Desvio 3) grava pela equipe" do
    expect(described_class.registrar?(acs, team, ficha: :individual)).to eq(:ok)
  end

  it "registrar?: microárea de outra equipe → out_of_scope, mesmo para o enfermeiro" do
    foreign = registry_micro_area!(code: "01", team: registry_team!(care_unit!))
    expect(described_class.registrar?(nurse, team, micro_area: foreign, ficha: :individual)).to eq(:out_of_scope)
  end

  it "registrar?: membro com CBO fora do papel (técnico, dentista) → cbo_not_allowed" do
    expect(described_class.registrar?(member_with("322205"), team, micro_area: area, ficha: :individual)).to eq(:cbo_not_allowed)
  end

  it "registrar?: CBO do papel mas fora da Tabela 1/2 do LEDI → cbo_not_allowed (Desvio 4)" do
    tables = YAML.load_file(Rails.root.join("config/ledi/registration_cbos.yml"))
    outside = %w[225151 225325 223510 225210].find { |cbo| !tables["individual"].include?(cbo) }
    expect(outside).to be_present
    expect(described_class.registrar?(member_with(outside), team, micro_area: area, ficha: :individual)).to eq(:cbo_not_allowed)
  end

  it "registrar?: o CBO conta por ficha (Tabela 1 × Tabela 2)" do
    # Hoje nenhum CBO do papel está só numa das tabelas; o stub prova que a ficha chega à checagem.
    allow(described_class).to receive(:registrar_cbo?).and_call_original
    allow(described_class).to receive(:registrar_cbo?).with("223505", ficha: :household).and_return(false)
    expect(described_class.registrar?(nurse, team, micro_area: area, ficha: :individual)).to eq(:ok)
    expect(described_class.registrar?(nurse, team, micro_area: area, ficha: :household)).to eq(:cbo_not_allowed)
  end

  it "visible_micro_area_ids: enfermeiro vê todas da equipe; ACS só as suas; outro membro e quem é de fora, nenhuma" do
    area
    other_area
    expect(described_class.visible_micro_area_ids(nurse, team)).to contain_exactly(area.id, other_area.id)
    expect(described_class.visible_micro_area_ids(acs, team)).to eq([ area.id ])
    expect(described_class.visible_micro_area_ids(registry_acs!(care_unit!), team)).to eq([])
    expect(described_class.visible_micro_area_ids(member_with("322205"), team)).to eq([])
  end

  # Módulo 24b (Q11; ruling A5b): o CBO de campo que não é ACS lê (só lê) as
  # microáreas atribuídas a ele; ACS, enfermeiro e quem é de fora, nenhuma por
  # aqui. A escrita não muda.
  it "field_reader_micro_area_ids: só as microáreas com atribuição ativa do CBO de campo; encerrada sai na hora" do
    area
    tacs = member_with("322255")
    assignment = MicroAreaFieldAssignment.create!(micro_area: other_area, professional: tacs.professional, assigned_by_user: acs)
    expect(described_class.field_reader_micro_area_ids(tacs, team, home_visits: true)).to eq([ other_area.id ])
    expect(described_class.field_reader_micro_area_ids(tacs, team, home_visits: false)).to eq([]) # Q48: sem o interruptor, só o 24a
    expect(described_class.field_reader_micro_area_ids(acs, team, home_visits: true)).to eq([])
    expect(described_class.field_reader_micro_area_ids(care_admin!, team, home_visits: true)).to eq([])
    expect(described_class.visible_micro_area_ids(tacs, team)).to eq([])
    expect(described_class.registrar?(tacs, team, micro_area: other_area, ficha: :individual)).to eq(:cbo_not_allowed)
    assignment.update!(ended_at: Time.current, ended_by_user: acs)
    expect(described_class.field_reader_micro_area_ids(tacs, team, home_visits: true)).to eq([])
  end
end

# Módulo 35a (ADR 0054; contrato §20 Q13(1), Q14): com vector_control
# utilizável, o agente de endemias (515140) grava a ficha domiciliar só de
# imóvel não residencial (2 3 4 5 6 12 13), nas microáreas atribuídas a ele.
# Residencial, troca para residencial, edição de residencial e cadastro
# individual → cbo_not_allowed; sem atribuição → out_of_scope. O resto não muda.
RSpec.describe TerritoryRegistry::Access, "agente de endemias (módulo 35a)", type: :model do
  before { vector_city! }

  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }
  let(:agent) { endemic_agent!(team: team) }
  let(:assigned) { MicroAreaFieldAssignment.active.find_by!(professional_id: agent.professional.id).micro_area }
  let(:other_area) { registry_micro_area!(code: "02", team: team) }

  def check(user = agent, ficha: :household, micro_area: assigned, vector_control: true, **types)
    described_class.registrar?(user, team, ficha: ficha, micro_area: micro_area, vector_control: vector_control, **types)
  end

  it "515140 com gate e microárea atribuída: :household tipo 4 → :ok; tipo 1 → :cbo_not_allowed; :individual → :cbo_not_allowed" do
    expect(check(property_type: "4")).to eq(:ok)
    expect(HomeVisits::Catalog::NON_RESIDENTIAL.map { check(property_type: _1) }).to all(eq(:ok))
    expect(check).to eq(:ok) # o contexto de cadastro (GET /territory/teams), sem tipo
    expect(check(property_type: "1")).to eq(:cbo_not_allowed)
    expect(HomeVisits::Catalog::RESIDENTIAL.map { check(property_type: _1) }).to all(eq(:cbo_not_allowed))
    expect(check(ficha: :individual, property_type: "4")).to eq(:cbo_not_allowed)
    expect(check(ficha: :individual)).to eq(:cbo_not_allowed)
  end

  it "sem gate → :cbo_not_allowed" do
    expect(check(vector_control: false, property_type: "4")).to eq(:cbo_not_allowed)
    expect(described_class.registrar?(agent, team, ficha: :household, micro_area: assigned)).to eq(:cbo_not_allowed)
  end

  it "microárea não atribuída → :out_of_scope (outra da equipe, sem microárea, atribuição encerrada, outra equipe)" do
    assigned
    expect(check(micro_area: other_area, property_type: "4")).to eq(:out_of_scope)
    expect(check(micro_area: nil, property_type: "4")).to eq(:out_of_scope)
    foreign = registry_micro_area!(code: "01", team: registry_team!(care_unit!))
    expect(check(micro_area: foreign, property_type: "4")).to eq(:out_of_scope)
    MicroAreaFieldAssignment.active.find_by!(professional_id: agent.professional.id).update!(ended_at: Time.current, ended_by_user: agent)
    expect(check(property_type: "4")).to eq(:out_of_scope)
  end

  it "domicílio atual tipo 1 com corpo tipo 2 → :cbo_not_allowed; não residencial atual com corpo não residencial → :ok" do
    expect(check(property_type: "2", current_property_type: "1")).to eq(:cbo_not_allowed)
    expect(check(property_type: "1", current_property_type: "2")).to eq(:cbo_not_allowed)
    expect(check(property_type: "3", current_property_type: "2")).to eq(:ok)
  end

  it "ACS e enfermeiro como antes; o TACS (515130) atribuído segue :cbo_not_allowed" do
    acs = registry_acs!(unit, team: team)
    mine = registry_micro_area!(code: "01", team: team, acs: acs)
    nurse = registry_nurse!(unit, team: team)
    [ true, false ].each do |gate|
      expect(check(acs, micro_area: mine, vector_control: gate, property_type: "1", current_property_type: "1")).to eq(:ok)
      expect(check(acs, micro_area: other_area, vector_control: gate, property_type: "4")).to eq(:out_of_scope)
      expect(check(acs, ficha: :individual, micro_area: mine, vector_control: gate)).to eq(:ok)
      expect(check(nurse, micro_area: other_area, vector_control: gate, property_type: "1")).to eq(:ok)
      expect(check(nurse, ficha: :individual, micro_area: assigned, vector_control: gate)).to eq(:ok)
    end
    tacs = field_agent!(cbo: "515130", team: team)
    assignment!(assigned, tacs.professional)
    expect(check(tacs, property_type: "4")).to eq(:cbo_not_allowed)
  end

  it "visible_micro_area_ids: as atribuídas ao 515140 só com vector_control; ACS e enfermeiro sem mudança" do
    acs = registry_acs!(unit, team: team)
    mine = registry_micro_area!(code: "01", team: team, acs: acs)
    other_area
    expect(described_class.visible_micro_area_ids(agent, team, vector_control: true)).to eq([ assigned.id ])
    expect(described_class.visible_micro_area_ids(agent, team)).to eq([])
    expect(described_class.visible_micro_area_ids(acs, team, vector_control: true)).to eq([ mine.id ])
    expect(described_class.visible_micro_area_ids(registry_nurse!(unit, team: team), team, vector_control: true))
      .to contain_exactly(mine.id, other_area.id, assigned.id)
  end

  it "endemic_registration: as microáreas atribuídas e a lista não residencial para o 515140 com o gate; nil para o resto" do
    other_area
    expect(described_class.endemic_registration(agent, team, vector_control: true))
      .to eq(micro_area_ids: [ assigned.id ], property_types: %w[2 3 4 5 6 12 13])
    expect(described_class.endemic_registration(agent, team, vector_control: false)).to be_nil
    expect(described_class.endemic_registration(registry_acs!(unit, team: team), team, vector_control: true)).to be_nil
    expect(described_class.endemic_registration(registry_nurse!(unit, team: team), team, vector_control: true)).to be_nil
  end
end
