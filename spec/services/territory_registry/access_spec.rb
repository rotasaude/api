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
end
