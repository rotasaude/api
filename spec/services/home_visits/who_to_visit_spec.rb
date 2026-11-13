require "rails_helper"

# Módulo 24b (ADR 0052; contrato §8, §16 Q33; plano, Task 18): "quem visitar"
# por microárea. População = cadastro individual ativo com domicílio na
# microárea, sem óbito. Três motivos: care_line (prática acs_visit em overdue
# ou due_soon de inscrição ativa, avaliada com home_visits: true; só com
# care_lines utilizável; nunca CID, problema ou condição), registration_due
# (TerritoryRegistry::Validity due_soon/expired) e never_visited (nenhuma
# visita não retirada com outcome = 1). Só entra quem tem motivo. Ordem
# display_name, patient_id; cursor opaco do person_ref; limit nil = tudo
# (download do app, Task 22).
RSpec.describe HomeVisits::WhoToVisit, type: :model do
  before { home_visit_city! }

  let(:today) { Time.zone.today }
  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }
  let(:acs) { field_agent!(team: team) }
  let(:nurse) { registry_nurse!(unit, team: team) }
  let(:area) { registry_micro_area!(code: "01", team: team, acs: acs) }
  let(:household) { registry_household!(micro_area: area) }

  def page(**over)
    described_class.page(micro_area: area, before: nil, limit: 50, today: today, care_lines: true, home_visits: true, **over)
  end

  def count(**over) = described_class.count(micro_area: area, today: today, care_lines: true, home_visits: true, **over)

  def person!(name = "Joana Ribeiro Lima", birth_date: (today - 40.years).iso8601)
    Patient.create!(cpf: valid_cpf(registry_seq!), full_name: name, mother_name: "Rita Lima", birth_date: birth_date, sex: "female",
                    race_color: "03")
  end

  # Morador da microárea: cadastro pelo caminho real (válido, gravado agora)
  # ou, com `over` (ex.: registered_at), as linhas direto.
  def resident!(patient = person!, at: household, **over)
    registry_registration!(patient: patient, household: at, **over)
    patient
  end

  def visit!(patient, outcome: 1, days_ago: 3)
    day = HomeVisitDay.find_by(user: acs, day: today - days_ago) || home_visit_day!(agent: acs, day: today - days_ago)
    home_visit!(day: day, micro_area: area, subject: "resident", patient: patient, outcome: outcome, has_reason: outcome == 1)
  end

  def registered_due_in(days) = ((today + days) << 24).in_time_zone.change(hour: 10)

  def ids(result) = result[:items].map { |item| item[:patient_id] }

  it "gestante com c3_e vencida entra com care_line, nome da linha e prática, sem CID" do
    pregnant = care_patient!(age: 28, sex: "female", problems: [ %w[ciap2 W78] ], unit: unit)
    resident!(pregnant)
    care_enrollment!(patient: pregnant, line: adopted_line!("pregnancy_c3"), team: team, by: nurse, anchor_date: today - 300)
    visit!(pregnant, days_ago: 3)

    item = page[:items].sole
    expect(item).to eq(
      patient_id: pregnant.id, display_name: pregnant.display_name, age: 28,
      household: { id: household.id, address_short: "Rua das Flores, 120" }, family_id: nil,
      micro_area: { id: area.id, code: "01" }, last_visit_on: (today - 3).iso8601,
      reasons: [ { code: "care_line", care_line: "Gestante e puérpera", practice: "3 visitas do ACS após a 1ª consulta",
                   status: "overdue", due_on: (today - 6).iso8601 } ]
    )
    text = page.to_json
    expect(text).not_to include("W78")
    expect(text).not_to include("pregnancy")
  end

  it "cadastro a 50 dias de vencer entra com registration_due; vencido também" do
    soon = resident!(person!("Ana"), registered_at: registered_due_in(50))
    late = resident!(person!("Bia"), registered_at: registered_due_in(-1))
    fresh = resident!(person!("Cris"))
    [ soon, late, fresh ].each { |patient| visit!(patient) }

    result = page
    expect(ids(result)).to eq([ soon.id, late.id ])
    expect(result[:items].map { |item| item[:reasons] }).to eq([
      [ { code: "registration_due", status: "due_soon", due_on: (today + 50).iso8601 } ],
      [ { code: "registration_due", status: "expired", due_on: (today - 1).iso8601 } ]
    ])
  end

  it "quem tem visita realizada não entra por never_visited; quem só tem recusa entra; retirada não conta" do
    done = resident!(person!("Ana"))
    refused = resident!(person!("Bia"))
    withdrawn = resident!(person!("Cris"))
    visit!(done)
    visit!(refused, outcome: 2)
    visit!(withdrawn).update!(withdrawn_at: Time.current, withdrawn_by_user: acs, withdrawal_reason: "Registrada na pessoa errada")

    result = page
    expect(ids(result)).to eq([ refused.id, withdrawn.id ])
    expect(result[:items].map { |item| [ item[:reasons], item[:last_visit_on] ] }).to eq([ [ [ { code: "never_visited" } ], nil ],
                                                                                           [ [ { code: "never_visited" } ], nil ] ])
  end

  it "sem motivo, fora; óbito fora; outra microárea fora" do
    quiet = resident!(person!("Ana"))
    visit!(quiet)
    dead = resident!(person!("Bia"))
    care_enrollment!(patient: dead, line: adopted_line!("elderly_c6"), team: team, by: nurse)
      .update!(status: "ended", ended_reason: "death", ended_at: 1.day.ago, ended_by_user: nurse)
    other_area = registry_micro_area!(code: "02", team: team, acs: field_agent!(team: team))
    resident!(person!("Cris"), at: registry_household!(micro_area: other_area))
    alive = resident!(person!("Dora"))

    expect(ids(page)).to eq([ alive.id ])
    expect(count).to eq(care_line: 0, registration_due: 0, never_visited: 1, people: 1)
  end

  it "care_lines desligado: só as duas outras fontes" do
    pregnant = resident!(person!("Ana", birth_date: (today - 28.years).iso8601), registered_at: registered_due_in(30))
    # DUM há 310 dias: c3_e venceu (DUM + 294) e o puerpério (c3_j, DUM + 336) vence em 26 dias.
    care_enrollment!(patient: pregnant, line: adopted_line!("pregnancy_c3"), team: team, by: nurse, anchor_date: today - 310)

    # c3_e vencida e c3_j (puerpério) a vencer: as duas práticas de visita.
    expect(page[:items].sole[:reasons].map { |reason| [ reason[:code], reason[:status] ] })
      .to eq([ %w[care_line overdue], %w[care_line due_soon], %w[registration_due due_soon], [ "never_visited", nil ] ])
    expect(page(care_lines: false)[:items].sole[:reasons].map { |reason| reason[:code] }).to eq(%w[registration_due never_visited])
    expect(count(care_lines: false)).to eq(care_line: 0, registration_due: 1, never_visited: 1, people: 1)
    # Sem home_visits a prática acs_visit é não rastreada: nada de care_line.
    expect(page(home_visits: false)[:items].sole[:reasons].map { |reason| reason[:code] }).to eq(%w[registration_due never_visited])
  end

  it "due_on (Q60): prática vencida sem prazo (janela móvel nunca cumprida, c5_d) → null; a vencer e cadastro sempre com data" do
    hypertensive = resident!(person!("Ana"), registered_at: registered_due_in(40))
    care_enrollment!(patient: hypertensive, line: adopted_line!("hypertension_c5"), team: team, by: nurse)
    puerperal = resident!(person!("Bia", birth_date: (today - 28.years).iso8601))
    visit!(puerperal, days_ago: 20) # dentro da janela da c3_e: ela não vence sem prazo
    care_enrollment!(patient: puerperal, line: adopted_line!("pregnancy_c3"), team: team, by: nurse, anchor_date: today - 310)

    reasons = page[:items].to_h { |item| [ item[:patient_id], item[:reasons] ] }
    expect(reasons.fetch(hypertensive.id)).to eq([
      { code: "care_line", care_line: "Pessoa com hipertensão", practice: "2 visitas do ACS nos últimos 12 meses", status: "overdue",
        due_on: nil },
      { code: "registration_due", status: "due_soon", due_on: (today + 40).iso8601 },
      { code: "never_visited" }
    ])
    expect(reasons.fetch(puerperal.id)).to include(
      { code: "care_line", care_line: "Gestante e puérpera", practice: "Visita do ACS no puerpério", status: "due_soon",
        due_on: (today + 26).iso8601 }
    )
  end

  it "membro de família que se mudou (moved_out) fica fora, mesmo com o cadastro ativo (Q61)" do
    stays = resident!(person!("Ana"))
    gone = person!("Bia")
    family = registry_family!(household, responsible: gone)
    resident!(gone, family_id: family.id)
    family.update!(moved_out: true)

    expect(ids(page)).to eq([ stays.id ])
    expect(count).to eq(care_line: 0, registration_due: 0, never_visited: 1, people: 1)
  end

  it "paciente sem nascimento sai com age null (Q33)" do
    patient = resident!(person!("Ana", birth_date: nil), registered_at: Time.current)
    expect(page[:items].sole).to include(patient_id: patient.id, age: nil)
  end

  it "reasons filtra pelos códigos: entra quem tem ao menos um deles, com todos os seus motivos" do
    due = resident!(person!("Ana"), registered_at: registered_due_in(10))
    never = resident!(person!("Bia"))
    visited_due = resident!(person!("Cris"), registered_at: registered_due_in(20))
    visit!(visited_due)

    expect(ids(page(reasons: %w[registration_due]))).to eq([ due.id, visited_due.id ])
    expect(page(reasons: %w[registration_due])[:items].first[:reasons].map { |r| r[:code] }).to eq(%w[registration_due never_visited])
    expect(ids(page(reasons: %w[never_visited]))).to eq([ due.id, never.id ])
    expect(count).to eq(care_line: 0, registration_due: 2, never_visited: 2, people: 3)
  end

  it "ordem display_name, patient_id (sem acento nem caixa), cursor opaco do person_ref, limit nil = tudo" do
    bruno = resident!(person!("Bruno"))
    alvaro = resident!(person!("álvaro"))
    carla = resident!(person!("Carla"))
    twins = [ resident!(person!("Bruno")), bruno ].sort_by(&:id)

    seen = []
    before = nil
    5.times do # teto: 4 pessoas em páginas de 2 não passam de 3 voltas
      result = page(limit: 2, before: before)
      seen.concat(ids(result))
      before = result[:next_before]
      break unless before

      expect(before).not_to include(seen.last)
      expect(before).not_to include("Bruno")
    end
    expect(before).to be_nil
    expect(seen).to eq([ alvaro.id, *twins.map(&:id), carla.id ])

    all = page(limit: nil)
    expect(ids(all)).to eq(seen)
    expect(all[:next_before]).to be_nil

    # Quem saiu da lista depois do cursor não perde a posição (nome do paciente).
    cursor = page(limit: 1)[:next_before]
    visit!(alvaro)
    expect(ids(page(limit: 2, before: cursor))).to eq(twins.map(&:id))

    expect { page(before: "não-é-cursor") }.to raise_error(described_class::InvalidCursor)
    expect { page(before: described_class.encode_cursor(SecureRandom.uuid)) }.to raise_error(described_class::InvalidCursor)
    # Paciente de outra microárea (Q61): o cursor não serve de oráculo nem posiciona a página.
    other_area = registry_micro_area!(code: "02", team: team, acs: field_agent!(team: team))
    outsider = resident!(person!("Bárbara"), at: registry_household!(micro_area: other_area))
    expect { page(before: described_class.encode_cursor(outsider.id)) }.to raise_error(described_class::InvalidCursor)
    expect { page(before: described_class.encode_cursor(registry_patient!.id)) }.to raise_error(described_class::InvalidCursor)
    expect { page(before: Base64.urlsafe_encode64("citizen:#{SecureRandom.uuid}", padding: false)) }
      .to raise_error(described_class::InvalidCursor)
  end

  it "o resultado não vaza pelo inspect (só ids e estado)" do
    patient = resident!(person!("Ana"), registered_at: registered_due_in(10))
    entry = described_class.entries(micro_area: area, today: today, care_lines: true, home_visits: true).sole
    expect(entry.inspect).to include(patient.id)
    [ entry.inspect, entry.to_s, entry.as_json.to_s ].each do |text|
      expect(text).not_to include((today + 10).iso8601)
      expect(text).not_to include("registration_due")
    end
  end

  # [consultas] do bloco (sem SCHEMA/TRANSACTION nem cache).
  def queries(&block)
    sql = []
    counter = ->(*, payload) { sql << payload[:sql] unless %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    sql.size
  end

  # n moradores no domicílio, em lote, metade com hipertensão (c5_d em atraso),
  # um terço com cadastro a vencer e visita para um em cada quatro.
  def bulk_residents!(count, offset:)
    now = Time.current
    line = adopted_line!("hypertension_c5")
    by = registry_acs_of(area).id
    patients = Array.new(count) do |i|
      { id: SecureRandom.uuid, cpf: valid_cpf(20_000 + offset + i), full_name: "Pessoa #{offset + i}", birth_date: "1960-01-01",
        sex: "female", created_at: now, updated_at: now }
    end
    Patient.insert_all!(patients)
    IndividualRegistration.insert_all!(patients.each_with_index.map do |p, i|
      { patient_id: p[:id], team_id: team.id, micro_area_id: area.id, household_id: household.id, refused: "false", version: 1,
        registered_at: i % 3 == 0 ? registered_due_in(20) : now, registered_by_user_id: by, created_at: now, updated_at: now }
    end)
    CareLineEnrollment.insert_all!(patients.each_with_index.select { |_, i| i.even? }.map do |p, _|
      { patient_id: p[:id], care_line_id: line.id, team_id: team.id, enrolled_by_user_id: nurse.id, enrolled_at: now - 400.days,
        source: "manual", status: "active", created_at: now, updated_at: now }
    end)
    patients.each_with_index { |p, i| visit!(Patient.find(p[:id]), days_ago: 2) if i % 4 == 0 }
  end

  it "consultas constantes: dezenas de pessoas na microárea não fazem consulta por paciente (página, tudo e contagem)" do
    household
    bulk_residents!(4, offset: 0)
    small = [ queries { page(limit: 2) }, queries { page(limit: nil) }, queries { count } ]
    small_people = count[:people]

    bulk_residents!(40, offset: 100)
    large = [ queries { page(limit: 2) }, queries { page(limit: nil) }, queries { count } ]
    expect(count[:people]).to be > small_people
    expect(count[:care_line]).to eq(22)
    expect(large).to eq(small)
    expect(large.max).to be <= 20
  end
end
