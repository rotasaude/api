require "rails_helper"

# Módulo 35a (ADR 0054; contrato §1, tabela de acesso): o agente de campo do
# boletim é só o ACE (515140) com papel :field na equipe; os papéis da cidade
# (coordenação, laboratório, leitura) pelo papel ativo.
RSpec.describe VectorControl::Access, type: :model do
  before { vector_city! }

  let(:team) { registry_team! }

  it "ACE 515140 atribuído é field_agent; TACS 515130 atribuído não; ACS não" do
    ace = endemic_agent!(team: team)
    expect(described_class.field_agent?(ace, team)).to be(true)
    expect(described_class.field_agent_somewhere?(ace)).to be(true)
    expect(HomeVisits::Access.scope(ace, team)[:micro_area_ids].size).to eq(1)

    tacs = field_agent!(cbo: "515130", team: team)
    assignment!(registry_micro_area!(code: "02", team: team), tacs.professional)
    expect(HomeVisits::Access.role(HomeVisits::Access.member(tacs, team))).to eq(:field)
    expect(described_class.field_agent?(tacs, team)).to be(false)
    expect(described_class.field_agent_somewhere?(tacs)).to be(false)

    acs = registry_acs!(team.health_unit, team: team)
    expect(described_class.field_agent?(acs, team)).to be(false)
    expect(described_class.field_agent_somewhere?(acs)).to be(false)

    expect(described_class.field_agent?(ace, registry_team!)).to be(false)
    expect(described_class.field_agent?(nil, team)).to be(false)
    expect(described_class.field_agent_somewhere?(nil)).to be(false)
    team.update!(active: false)
    expect(described_class.field_agent?(ace, team)).to be(false)
    expect(described_class.field_agent_somewhere?(ace)).to be(false)
  end

  it "coordinator?, lab? e reader? pelo papel ativo; municipal_admin só reader?" do
    coordinator = endemic_coordinator!
    lab = vector_lab!
    admin = staff_with("admin-#{SecureRandom.hex(4)}@cidade.gov.br", "municipal_admin")
    viewer = staff_with("leitor-#{SecureRandom.hex(4)}@cidade.gov.br", "viewer")

    expect([ coordinator, lab, admin, viewer ].map { |user| described_class.coordinator?(user) }).to eq([ true, false, false, false ])
    expect([ coordinator, lab, admin, viewer ].map { |user| described_class.lab?(user) }).to eq([ false, true, false, false ])
    expect([ coordinator, lab, admin, viewer ].map { |user| described_class.reader?(user) }).to eq([ true, true, true, false ])
    expect([ described_class.coordinator?(nil), described_class.lab?(nil), described_class.reader?(nil) ]).to eq([ false, false, false ])

    coordinator.memberships.active.find_by!(role: "endemic_coordinator").revoke!
    expect(described_class.coordinator?(coordinator)).to be(false)
    expect(described_class.reader?(coordinator)).to be(false)
  end

  # Q31: a regra de leitura dos relatórios (ReportsController) e das listas que
  # preenchem o filtro deles (ciclos, levantamentos LIRAa).
  it "reads_report?: coordenação e municipal_admin leem todos; o laboratório só LAB_REPORTS; o resto nenhum" do
    coordinator = endemic_coordinator!
    admin = municipal_admin!
    lab = vector_lab!
    viewer = staff_with("leitor-#{SecureRandom.hex(4)}@cidade.gov.br", "viewer")
    team = registry_team!
    ace = endemic_agent!(team: team)
    tacs = field_agent!(cbo: "322255", team: team)

    VectorControl::Catalog::REPORTS.each do |name|
      readers = [ coordinator, admin, lab, viewer, ace, tacs, nil ].map { |user| described_class.reads_report?(user, name) }
      lab_reads = VectorControl::Reports::LAB_REPORTS.include?(name)
      expect(readers).to eq([ true, true, lab_reads, false, false, false, false ]), name
    end
    expect(VectorControl::Reports::LAB_REPORTS).to contain_exactly("ovitraps", "liraa")
    expect(%w[situations strategic_points].map { |name| described_class.reads_report?(lab, name) }).to eq([ false, false ])

    admin.memberships.active.find_by!(role: "municipal_admin").revoke!
    expect(described_class.reads_report?(admin, "situations")).to be(false)
  end
end
