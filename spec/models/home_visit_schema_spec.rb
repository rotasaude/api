require "rails_helper"
require Rails.root.join("db/city_migrate/20261112900001_add_home_visits.rb").to_s

# Módulo 24b (ADR 0052): o banco das visitas. Uma folha aberta por (profissional,
# equipe, dia); folha fechada congela; a visita só muda a retirada, uma vez e só
# com a folha aberta; a atribuição só encerra, uma vez; nada se apaga; a re-cifra
# passa antes de tudo; nada de dado pessoal em inspect.
RSpec.describe "Esquema das visitas (ADR 0052)", type: :model do
  before { home_visit_city! }

  # Escrita crua que o banco recusa: sem savepoint a recusa aborta a transação do exemplo.
  def refused(pattern = nil, &block)
    expect { ApplicationRecord.transaction(requires_new: true, &block) }.to raise_error(ActiveRecord::StatementInvalid, pattern)
  end

  def accepted(&block)
    expect { ApplicationRecord.transaction(requires_new: true, &block) }.not_to raise_error
  end

  let(:team) { registry_team! }
  let(:agent) { field_agent!(team: team) }

  it "uma folha aberta por (profissional, equipe, dia); a segunda abre só com sequence nova depois de fechar" do
    first = home_visit_day!(agent: agent, team: team)
    expect { home_visit_day!(agent: agent, team: team, sequence: 2) }.to raise_error(ActiveRecord::RecordNotUnique, /idx_home_visit_days_one_open/)
    expect { home_visit_day!(agent: agent, team: team, state: "closed") }.to raise_error(ActiveRecord::RecordNotUnique, /idx_home_visit_days_sheet/)
    first.update!(state: "closed", closed_at: Time.current, closed_by: "full")
    second = home_visit_day!(agent: agent, team: team, sequence: 2)
    expect(second).to be_open
    expect(first.reload).to be_closed
    expect(HomeVisitDay.open_on(agent.professional, team, Time.zone.today)).to contain_exactly(second)
    expect(first.competence).to eq(Time.zone.today.strftime("%Y%m"))
    expect(first.inspect).to eq("#<HomeVisitDay id=#{first.id} state=closed>")
  end

  it "folha fechada não muda e não volta a open; closed_by_user_id só com user" do
    day = home_visit_day!(agent: agent, team: team)
    other = field_agent!(team: team)
    refused(/ck_home_visit_days_closed/) { home_visit_day!(agent: other, team: team, state: "open", closed_at: Time.current) }
    refused(/ck_home_visit_days_closed/) { home_visit_day!(agent: other, team: team, state: "closed", closed_by: "job", closed_by_user: other) }
    refused(/ck_home_visit_days_values/) { home_visit_day!(agent: other, team: team, state: "closed", closed_by: "other", closed_by_user: nil, validate: false) }
    refused(/home_visit_days/) { day.update_columns(closed_at: Time.current) }
    refused(/home_visit_days/) { day.update_columns(state: "closed", closed_at: Time.current, closed_by: "job", cbo: "515310") }
    refused(/home_visit_days/) { day.update_columns(cbo: "515310") }
    day.reload.update!(state: "closed", closed_at: Time.current, closed_by: "user", closed_by_user: agent)
    refused(/home_visit_days/) { day.update_columns(state: "open", closed_at: nil, closed_by: nil, closed_by_user_id: nil) }
    refused(/home_visit_days/) { day.update_columns(closed_by: "job", closed_by_user_id: nil) }
    refused(/home_visit_days/) { day.update_columns(cbo: "515310") }
  end

  it "visita: fora de área sem microárea; não residencial sem pessoa nem família; recusa sem motivo" do
    day = home_visit_day!(agent: agent, team: team)
    area = registry_micro_area!(code: "01", team: team, acs: agent)
    refused(/ck_home_visits_area/) { home_visit!(day: day, micro_area: area, out_of_area: true) }
    refused(/ck_home_visits_area/) { home_visit!(day: day, micro_area: nil, out_of_area: false) }
    patient = registry_patient!
    refused(/ck_home_visits_subject/) { home_visit!(day: day, subject: "resident", patient_id: nil) }
    refused(/ck_home_visits_subject/) { home_visit!(day: day, subject: "none", patient_id: patient.id) }
    refused(/ck_home_visits_family/) { home_visit!(day: day, subject: "family_responsible", patient_id: patient.id, family_id: nil) }
    refused(/ck_home_visits_non_residential/) { home_visit!(day: day, property_type: "2", subject: "resident", patient_id: patient.id) }
    refused(/ck_home_visits_outcome_reason/) { home_visit!(day: day, outcome: 2, has_reason: true) }
    refused(/ck_home_visits_values/) { home_visit!(day: day, outcome: 4, validate: false) }
    refused(/ck_home_visits_values/) { home_visit!(day: day, shift: 4) }
    refused(/ck_home_visits_origin/) { home_visit!(day: day, origin: "field_app") }
    refused(/ck_home_visits_origin/) { home_visit!(day: day, field_device_id: SecureRandom.uuid) }
    accepted { home_visit!(day: day, property_type: "2") }
    visit = home_visit!(day: day, micro_area: area, outcome: 2)
    expect(visit).to be_recorded
    expect(visit.inspect).to eq("#<HomeVisit id=#{visit.id} state=recorded>")
    expect(HomeVisit.valid).to include(visit)
    expect(visit.pretty_inspect.strip).to eq(visit.inspect)
    expect(day.pretty_inspect.strip).to eq(day.inspect)
    assignment = MicroAreaFieldAssignment.new(id: SecureRandom.uuid)
    expect(assignment.pretty_inspect.strip).to eq("#<MicroAreaFieldAssignment id=#{assignment.id} state=active>")
    expect(visit.to_s).to eq(visit.inspect)
  end

  # A real race needs committed rows and two sessions; at this layer the proof is
  # that the day read in the guard takes the row lock (FOR SHARE), so a close
  # (UPDATE) racing a withdrawal waits for it.
  it "o guard da visita trava a folha com FOR SHARE ao ler o estado" do
    body = ApplicationRecord.connection.select_value("SELECT pg_get_functiondef('rota_home_visit_guard'::regproc)")
    expect(body).to match(/FROM home_visit_days WHERE id = .* AND state = 'open' FOR SHARE/)
  end

  it "retirada exige os três campos juntos (CHECK)" do
    day = home_visit_day!(agent: agent, team: team)
    visit = home_visit!(day: day)
    refused(/ck_home_visits_withdrawn|home_visits/) { visit.update_columns(withdrawn_at: Time.current, withdrawn_by_user_id: agent.id) }
  end

  it "cifra reasons, measurements, note e withdrawal_reason (listas e objetos voltam como JSON)" do
    day = home_visit_day!(agent: agent, team: team)
    visit = home_visit!(day: day, reasons: [ 1, 29 ], has_reason: true, measurements: { "weight_kg" => 70.5 }, note: "porta fechada")
    raw = HomeVisit.connection.select_one("SELECT reasons, measurements, note FROM home_visits WHERE id = '#{visit.id}'")
    expect(raw.values.join).not_to include("porta fechada")
    expect(raw["reasons"]).not_to eq("[1,29]")
    loaded = HomeVisit.find(visit.id)
    expect([ loaded.reasons, loaded.measurements, loaded.note ]).to eq([ [ 1, 29 ], { "weight_kg" => 70.5 }, "porta fechada" ])
    expect(CityEncryption::CITY_KEYED_TARGETS).to include([ HomeVisit, :reasons ], [ HomeVisit, :measurements ],
                                                          [ HomeVisit, :note ], [ HomeVisit, :withdrawal_reason ])
  end

  it "visita só muda os três campos de retirada, uma vez, e só com a folha aberta" do
    day = home_visit_day!(agent: agent, team: team)
    visit = home_visit!(day: day, note: "obs")
    refused(/home_visits/) { visit.update_columns(outcome: 3) }
    refused(/home_visits/) { visit.update_columns(note: "outra") }
    refused(/home_visits/) { visit.update_columns(withdrawn_at: Time.current) } # sem o usuário (CHECK) e sem o motivo
    visit.update!(withdrawn_at: Time.current, withdrawn_by_user: agent, withdrawal_reason: "lançada por engano")
    expect(visit).to be_withdrawn
    expect(HomeVisit.valid).not_to include(visit)
    refused(/home_visits/) { visit.update_columns(withdrawn_at: Time.current + 1.minute) }
    refused(/home_visits/) { visit.update_columns(withdrawn_at: nil, withdrawn_by_user_id: nil, withdrawal_reason: nil) }

    closed_day = home_visit_day!(agent: field_agent!(team: team), team: team)
    other = home_visit!(day: closed_day)
    closed_day.update!(state: "closed", closed_at: Time.current, closed_by: "job")
    refused(/home_visits/) { other.update_columns(withdrawn_at: Time.current, withdrawn_by_user_id: agent.id, withdrawal_reason: "lançada por engano") }
    expect(other.reload).not_to be_withdrawn
  end

  it "nenhuma das três aceita DELETE nem TRUNCATE" do
    day = home_visit_day!(agent: agent, team: team)
    visit = home_visit!(day: day)
    area = registry_micro_area!(code: "02", team: team, acs: agent)
    assign = assignment!(area, agent.professional)
    refused(/home_visits/) { visit.delete }
    refused(/home_visit_days/) { day.delete }
    refused(/micro_area_field_assignments/) { assign.delete }
    %w[home_visits home_visit_days micro_area_field_assignments].each do |table|
      refused(/#{table}/) { HomeVisit.connection.execute("TRUNCATE #{table} CASCADE") }
    end
  end

  it "atribuição só encerra, uma vez; duas ativas iguais → RecordNotUnique" do
    area = registry_micro_area!(code: "03", team: team)
    assign = assignment!(area, agent.professional)
    expect { assignment!(area, agent.professional) }.to raise_error(ActiveRecord::RecordNotUnique)
    expect(MicroAreaFieldAssignment.active).to contain_exactly(assign)
    refused(/micro_area_field_assignments/) { assign.update_columns(professional_id: field_agent!(team: team).professional.id) }
    assign.update!(ended_at: Time.current, ended_by_user: assign.assigned_by_user)
    expect(MicroAreaFieldAssignment.active).to be_empty
    refused(/micro_area_field_assignments/) { assign.update_columns(ended_at: Time.current + 1.minute) }
    refused(/micro_area_field_assignments/) { assign.update_columns(ended_at: nil, ended_by_user_id: nil) }
    accepted { assignment!(area, agent.professional) }
  end

  it "re-cifra passa (SET LOCAL rota.reencrypting = 'on') em visita de folha fechada" do
    day = home_visit_day!(agent: agent, team: team)
    visit = home_visit!(day: day, note: "obs", reasons: [ 1 ], has_reason: true)
    day.update!(state: "closed", closed_at: Time.current, closed_by: "user", closed_by_user: agent)
    refused(/home_visits/) { visit.update_columns(note: "outra") }
    accepted do
      HomeVisit.connection.execute("SET LOCAL rota.reencrypting = 'on'")
      visit.update_columns(note: "re-cifrada", reasons: "[1]")
    end
    refused(/home_visits/) do
      HomeVisit.connection.execute("SET LOCAL rota.reencrypting = 'on'")
      visit.update_columns(outcome: 3)
    end
  end

  it "a migração é irreversível e espelha o catálogo" do
    expect { AddHomeVisits.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
    expect([ AddHomeVisits::OUTCOMES, AddHomeVisits::SUBJECTS, AddHomeVisits::ORIGINS, AddHomeVisits::CLOSED_BY,
             AddHomeVisits::NON_RESIDENTIAL, AddHomeVisits::PROPERTY_TYPES ])
      .to eq([ HomeVisits::Catalog::OUTCOMES.keys, HomeVisits::Catalog::SUBJECTS, HomeVisits::Catalog::ORIGINS,
               HomeVisits::Catalog::CLOSED_BY, HomeVisits::Catalog::NON_RESIDENTIAL, TerritoryRegistry::Catalog::PROPERTY_TYPES ])
  end
end
