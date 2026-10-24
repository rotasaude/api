require "rails_helper"

# Módulo 24a (contrato §3): as duas recusas que o banco de hoje não deixa
# chegar pela rota — o CHECK de health_teams.kind só aceita 70/76 e o CNS do
# profissional é NOT NULL e validado. As checagens ficam (defesa para tipo novo
# no CNES e para CNS apagado por fora) e são testadas direto.
RSpec.describe TerritoryRegistry::SaveMicroArea do
  before { registry_city! }

  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }

  it "team_kind_allowed?: só eSF (70) e eAP (76), mesmo que o CNES traga outro tipo" do
    expect(described_class.team_kind_allowed?(HealthTeam.new(kind: "70"))).to be(true)
    expect(described_class.team_kind_allowed?(HealthTeam.new(kind: "76"))).to be(true)
    expect(described_class.team_kind_allowed?(HealthTeam.new(kind: "71"))).to be(false)
  end

  it "equipe de tipo fora de 70/76 → team_kind_not_allowed, nada gravado" do
    allow(described_class).to receive(:team_kind_allowed?).and_return(false)
    result = described_class.call(params: { "team_id" => team.id, "code" => "01", "name" => "Norte" }, by: care_admin!)
    expect(result.reason).to eq(:team_kind_not_allowed)
    expect(MicroArea.count).to eq(0)
  end

  it "acs_check: membro ACS ativo com CNS → nil; sem CNS → acs_without_cns; de fora ou sem perfil → acs_not_in_team" do
    acs = registry_acs!(unit, team: team).professional
    expect(described_class.acs_check(team, acs)).to be_nil
    acs.cns = ""
    expect(described_class.acs_check(team, acs)).to eq(:acs_without_cns)
    expect(described_class.acs_check(team, Professional.new(cns: ""))).to eq(:acs_not_in_team)
    expect(described_class.acs_check(team, nil)).to eq(:acs_not_in_team)
    expect(described_class.acs_check(registry_team!(care_unit!), registry_acs!(unit, team: team).professional)).to eq(:acs_not_in_team)
  end

  it "o evento leva só ids e o autor" do
    result = described_class.call(params: { "team_id" => team.id, "code" => "01", "name" => "Norte" }, by: care_admin!)
    area = result.payload[:micro_area]
    expect(DomainEvent.where(name: "micro_area.changed").last.payload)
      .to eq("micro_area_id" => area.id, "team_id" => team.id, "user_id" => care_admin!.id)
  end

  it "corrida no código: o índice único vira duplicate_code, não 500" do
    registry_micro_area!(code: "01", team: team)
    allow(MicroArea).to receive(:exists?).and_return(false) # a pré-checagem do perdedor passa
    result = described_class.call(params: { "team_id" => team.id, "code" => "01", "name" => "Norte" }, by: care_admin!)
    expect(result.reason).to eq(:duplicate_code)
  end
end
