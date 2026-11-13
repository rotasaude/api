require "rails_helper"

# Módulo 24b (ADR 0052; contrato §1, tabela "Acesso à visita"; 6A; Q11; ruling
# A3): quem registra visita, o que cada um lê, quem atribui microárea e quem
# cadastra aparelho. Sempre papel health_professional e vínculo ativo em equipe
# 70/76.
RSpec.describe HomeVisits::Access, type: :model do
  before { home_visit_city! }

  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }
  let(:acs) { registry_acs!(unit, team: team) }
  let(:colleague) { registry_acs!(unit, team: team) }
  let(:tacs) { field_agent!(cbo: "322255", team: team) }
  let(:nurse) { registry_nurse!(unit, team: team) }
  let(:doctor) { field_agent!(cbo: "225142", team: team) }
  let(:area) { registry_micro_area!(code: "01", team: team, acs: acs) }
  let(:colleague_area) { registry_micro_area!(code: "02", team: team, acs: colleague) }
  let(:open_area) { registry_micro_area!(code: "03", team: team) }

  def end_assignment!(assignment) = assignment.update!(ended_at: Time.current, ended_by_user: nurse)

  it "role: 515105 é :acs, outro da Tabela 7 é :field, enfermeiro/médico é :reader, o resto nil" do
    expect(described_class.role(described_class.member(acs, team))).to eq(:acs)
    expect(described_class.role(described_class.member(tacs, team))).to eq(:field)
    expect(described_class.role(described_class.member(field_agent!(cbo: "515140", team: team), team))).to eq(:field)
    expect(described_class.role(described_class.member(nurse, team))).to eq(:reader)
    expect(described_class.role(described_class.member(doctor, team))).to eq(:reader)
    expect(described_class.role(described_class.member(field_agent!(cbo: "322245", team: team), team))).to be_nil
    expect(described_class.role(nil)).to be_nil
  end

  it "member: só equipe 70/76 ativa" do
    expect(described_class.member(acs, team)).to have_attributes(health_team_id: team.id, cbo_code: "515105")
    other = HealthTeam.create!(health_unit: unit, ine: format("%010d", SecureRandom.random_number(10**10)), kind: "71", name: "eSB")
    dentist_team_agent = field_agent!(cbo: "515105", team: other)
    expect(described_class.member(dentist_team_agent, other)).to be_nil
    team.update!(active: false)
    expect(described_class.member(acs, team)).to be_nil
  end

  it "ACS registra na sua microárea e fora de área; não na do colega (out_of_scope)" do
    expect(described_class.registers?(acs, team, micro_area: area, out_of_area: false)).to eq(:ok)
    expect(described_class.registers?(acs, team, micro_area: nil, out_of_area: true)).to eq(:ok)
    expect(described_class.registers?(acs, team, micro_area: colleague_area, out_of_area: false)).to eq(:out_of_scope)
    expect(described_class.registers?(acs, team, micro_area: open_area, out_of_area: false)).to eq(:out_of_scope)
    expect(described_class.scope(acs, team)).to eq(micro_area_ids: [ area.id ], kind: "responsible")
    expect(described_class.reads_micro_area?(acs, area)).to be(true)
    expect(described_class.reads_micro_area?(acs, colleague_area)).to be(false)
    expect(described_class.reads_team?(acs, team)).to be(false)
  end

  it "microárea de outra equipe → out_of_scope, mesmo para o ACS responsável dela" do
    foreign_team = registry_team!(care_unit!)
    foreign = registry_micro_area!(code: "01", team: foreign_team, acs: acs)
    expect(described_class.registers?(acs, team, micro_area: foreign, out_of_area: false)).to eq(:out_of_scope)
  end

  it "TACS só na atribuída; fora de área → out_of_scope" do
    assignment!(open_area, tacs.professional, by: nurse)
    expect(described_class.registers?(tacs, team, micro_area: open_area, out_of_area: false)).to eq(:ok)
    expect(described_class.registers?(tacs, team, micro_area: area, out_of_area: false)).to eq(:out_of_scope)
    expect(described_class.registers?(tacs, team, micro_area: nil, out_of_area: true)).to eq(:out_of_scope)
    expect(described_class.scope(tacs, team)).to eq(micro_area_ids: [ open_area.id ], kind: "assigned")
    expect(described_class.reads_micro_area?(tacs, open_area)).to be(true)
    expect(described_class.reads_micro_area?(tacs, area)).to be(false)
  end

  it "enfermeiro e médico leem a equipe e não registram (cbo_not_allowed)" do
    ids = [ area, colleague_area, open_area ].map(&:id)
    [ nurse, doctor ].each do |reader|
      expect(described_class.registers?(reader, team, micro_area: area, out_of_area: false)).to eq(:cbo_not_allowed)
      expect(described_class.registers?(reader, team, micro_area: nil, out_of_area: true)).to eq(:cbo_not_allowed)
      expect(described_class.reads_team?(reader, team)).to be(true)
      expect(described_class.reads_micro_area?(reader, open_area)).to be(true)
      expect(described_class.scope(reader, team)).to include(kind: "team")
      expect(described_class.scope(reader, team)[:micro_area_ids]).to match_array(ids)
    end
    expect(described_class.assigner?(nurse, team)).to be(true)
    expect(described_class.assigner?(doctor, team)).to be(false)
    expect(described_class.assigner?(acs, team)).to be(false)
  end

  it "municipal_admin não lê nem registra" do
    admin = care_admin!
    expect(described_class.reads_team?(admin, team)).to be(false)
    expect(described_class.reads_micro_area?(admin, area)).to be(false)
    expect(described_class.registers?(admin, team, micro_area: area, out_of_area: false)).to eq(:out_of_scope)
    expect(described_class.scope(admin, team)).to eq(micro_area_ids: [], kind: nil)
    expect(described_class.assigner?(admin, team)).to be(false)
    expect(described_class.device_owner?(admin)).to be_nil
  end

  it "atribuição encerrada tira o escopo na hora" do
    assignment = assignment!(open_area, tacs.professional, by: nurse)
    expect(described_class.reads_micro_area?(tacs, open_area)).to be(true)
    end_assignment!(assignment)
    expect(described_class.registers?(tacs, team, micro_area: open_area, out_of_area: false)).to eq(:out_of_scope)
    expect(described_class.reads_micro_area?(tacs, open_area)).to be(false)
    expect(described_class.scope(tacs, team)).to eq(micro_area_ids: [], kind: "assigned")
    expect(TerritoryRegistry::Access.field_reader_micro_area_ids(tacs, team, home_visits: true)).to eq([])
  end

  it "vínculo encerrado (ended_on) tira tudo" do
    area
    assignment!(open_area, tacs.professional, by: nurse)
    [ acs, tacs, nurse ].each do |user|
      HealthTeamMember.find_by!(professional: user.professional, health_team: team).update!(ended_on: Time.zone.today)
      expect(described_class.member(user, team)).to be_nil
      expect(described_class.scope(user, team)).to eq(micro_area_ids: [], kind: nil)
      expect(described_class.registers?(user, team, micro_area: open_area, out_of_area: false)).to eq(:out_of_scope)
      expect(described_class.reads_micro_area?(user, open_area)).to be(false)
      expect(described_class.reads_team?(user, team)).to be(false)
      expect(described_class.device_owner?(user)).to be_nil
    end
    expect(described_class.assigner?(nurse, team)).to be(false)
  end

  it "device_owner?: Tabela 7 com vínculo ativo em equipe 70/76; enfermeiro e médico não" do
    expect(described_class.device_owner?(acs)).to have_attributes(health_team_id: team.id, cbo_code: "515105")
    expect(described_class.device_owner?(tacs)).to have_attributes(cbo_code: "322255")
    expect(described_class.device_owner?(nurse)).to be_nil
    expect(described_class.device_owner?(doctor)).to be_nil
    other = HealthTeam.create!(health_unit: unit, ine: format("%010d", SecureRandom.random_number(10**10)), kind: "71", name: "eSB")
    expect(described_class.device_owner?(field_agent!(cbo: "515105", team: other))).to be_nil
  end

  # Q11: o CBO de campo que não é ACS lê o 24a só nas microáreas atribuídas.
  it "field_reader_micro_area_ids (24a): só as atribuídas e ativas do CBO de campo; vazio para ACS, enfermeiro e admin" do
    assignment!(open_area, tacs.professional, by: nurse)
    expect(TerritoryRegistry::Access.field_reader_micro_area_ids(tacs, team, home_visits: true)).to eq([ open_area.id ])
    expect(TerritoryRegistry::Access.field_reader_micro_area_ids(tacs, team, home_visits: false)).to eq([])
    expect(TerritoryRegistry::Access.field_reader_micro_area_ids(acs, team, home_visits: true)).to eq([])
    expect(TerritoryRegistry::Access.field_reader_micro_area_ids(nurse, team, home_visits: true)).to eq([])
    expect(TerritoryRegistry::Access.field_reader_micro_area_ids(care_admin!, team, home_visits: true)).to eq([])
    # A escrita do 24a não muda: o TACS segue cbo_not_allowed.
    expect(TerritoryRegistry::Access.registrar?(tacs, team, ficha: :household, micro_area: open_area)).to eq(:cbo_not_allowed)
    expect(TerritoryRegistry::Access.visible_micro_area_ids(tacs, team)).to eq([])
  end
end

# Módulo 24b (contrato §7): atividade coletiva pela Tabela 5.
RSpec.describe CollectiveActivities::Access, type: :model do
  before { home_visit_city!(collective: true) }

  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }
  let(:nurse) { registry_nurse!(unit, team: team) }
  let(:acs) { registry_acs!(unit, team: team) }

  it "registers?: membro ativo com CBO da Tabela 5; fora dela ou fora da equipe, não" do
    expect(described_class.registers?(nurse, team)).to be(true)
    expect(described_class.registers?(acs, team)).to be(true)
    expect(described_class.registers?(field_agent!(cbo: "225151", team: team), team)).to be(false)
    expect(described_class.registers?(nurse, registry_team!(care_unit!))).to be(false)
    expect(described_class.registers?(care_admin!, team)).to be(false)
  end

  it "reads?: quem registra, ou enfermeiro/médico da equipe mesmo fora da Tabela 5" do
    reader = field_agent!(cbo: "225151", team: team)
    expect(described_class.reads?(reader, team)).to be(true)
    expect(described_class.reads?(acs, team)).to be(true)
    expect(described_class.reads?(field_agent!(cbo: "221205", team: team), team)).to be(false)
    expect(described_class.reads?(care_admin!, team)).to be(false)
  end

  it "marker?: só quem registrou" do
    activity = CollectiveActivity.new(recorded_by_user_id: nurse.id)
    expect(described_class.marker?(nurse, activity)).to be(true)
    expect(described_class.marker?(acs, activity)).to be(false)
  end
end

# Pre-flight 4.2: o primeiro dia aceito pelo prazo do SIAPS (contexto, regras e sessão).
RSpec.describe "HomeVisits::Rules.min_date", type: :model do
  it "primeiro dia da competência mais antiga cujo prazo ainda não passou (siaps_deadlines.yml)" do
    # 202610 vence em 2026-11-16 (tabela); 202609 em 2026-10-15.
    expect(HomeVisits::Rules.min_date(Date.new(2026, 11, 12))).to eq(Date.new(2026, 10, 1))
    expect(HomeVisits::Rules.min_date(Date.new(2026, 11, 15))).to eq(Date.new(2026, 10, 1))
    expect(HomeVisits::Rules.min_date(Date.new(2026, 11, 16))).to eq(Date.new(2026, 11, 1))
    expect(HomeVisits::Rules.min_date(Date.new(2026, 11, 30))).to eq(Date.new(2026, 11, 1))
    expect(HomeVisits::Rules.min_date(Date.new(2026, 10, 15))).to eq(Date.new(2026, 10, 1))
    expect(HomeVisits::Rules.min_date(Date.new(2026, 10, 14))).to eq(Date.new(2026, 9, 1))
  end
end

# Contrato §13: trilha da leitura nominal da visita, só ids.
RSpec.describe HomeVisits::Trail, type: :model do
  before { home_visit_city! }

  it "clinical_record.viewed com access home_visits (ou field_sync), só ids" do
    user = registry_nurse!
    visit_id = SecureRandom.uuid
    patient_id = SecureRandom.uuid
    described_class.visits_viewed!(user: user, home_visit_ids: [ visit_id ], patient_ids: [ patient_id, patient_id ])
    described_class.person_viewed!(user: user, patient_id: patient_id, access: HomeVisits::Catalog::FIELD_TRAIL_ACCESS)
    first, second = DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at).map(&:payload)
    expect(first).to eq("access" => "home_visits", "home_visit_ids" => [ visit_id ], "patient_ids" => [ patient_id ], "user_id" => user.id)
    expect(second).to eq("access" => "field_sync", "patient_id" => patient_id, "user_id" => user.id, "reason_code" => nil,
                         "person_ref" => "patient:#{patient_id}")
  end
end
