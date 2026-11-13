require "rails_helper"

# Módulo 24b (ADR 0052; contrato §1, §2, §3, §5, §13; Q6, Q21, Q40–Q44; plano,
# Task 8, Desvio 2; pre-flight 1.8, 1.9): o registro da visita. Idempotente pelo
# client_uuid; acesso e escopo pelo HomeVisits::Access; travas paciente →
# domicílio → folha (trava consultiva por profissional+equipe+dia) → visita; a
# folha abre na primeira visita do dia, a complementar depois de uma fechada, e
# a 100ª visita não retirada fecha a cheia (closed_by full, ficha gerada) e abre
# a próxima. Todas as regras antes de qualquer escrita; recusa não deixa nada.
RSpec.describe HomeVisits::Record, type: :model do
  let!(:city) { home_visit_city! }
  let(:team) { registry_team! }
  let(:acs) { field_agent!(team: team) }
  let(:area) { registry_micro_area!(code: "01", team: team, acs: acs) }
  let(:today) { Time.zone.today }

  before { allow(Ledi::DeliverJob).to receive(:perform_later) }

  def at_now = Time.current.change(usec: 0)

  def body(**over)
    { "client_uuid" => SecureRandom.uuid, "team_id" => team.id, "occurred_at" => at_now.iso8601, "micro_area_id" => area.id,
      "property_type" => "1", "subject" => "none", "outcome" => 1, "reasons" => [ 1 ], "shared" => false }.merge(over.stringify_keys)
  end

  def household_body(household, **over)
    body(**over).except("micro_area_id", "property_type").merge("household_id" => household.id).merge(over.stringify_keys)
  end

  def record(params = body, by: acs, **opts) = described_class.call(params: params, by: by, **opts)
  def recorded_events = DomainEvent.where(name: "home_visit.recorded")
  def entries_of(day) = LediOutboxEntry.where(source_type: "HomeVisitDay", source_id: day.id)
  def failure(result) = [ result.reason, result.details[:path] ]

  it "a primeira visita do dia abre a folha 1 com o CBO do vínculo (TACS atribuído)" do
    tacs = field_agent!(cbo: "322255", team: team)
    assignment!(area, tacs.professional)
    result = record(body(reasons: [ 1, 27 ], note: "  portão azul  "), by: tacs)
    expect(result).to be_ok
    expect(result.payload[:replayed]).to be(false)
    day = result.payload[:day]
    expect(day).to have_attributes(professional_id: tacs.professional.id, user_id: tacs.id, team_id: team.id, cbo: "322255",
                                   day: today, sequence: 1, state: "open")
    visit = result.payload[:visit].reload
    expect(visit).to have_attributes(home_visit_day_id: day.id, micro_area_id: area.id, out_of_area: false, subject: "none",
                                     patient_id: nil, property_type: "1", outcome: 1, has_reason: true, reasons: [ 1, 27 ],
                                     note: "portão azul", origin: "dashboard", field_device_id: nil, recorded_by_user_id: tacs.id,
                                     shift: HomeVisits::Rules.shift(visit.occurred_at))
    second = record(body(reasons: []), by: tacs)
    expect(second.payload[:day].id).to eq(day.id)
    expect(second.payload[:visit].reload.has_reason).to be(false)
    expect(HomeVisitDay.count).to eq(1)
  end

  it "o mesmo client_uuid devolve a gravada sem novo evento; de outro usuário → client_uuid_conflict" do
    params = body
    first = record(params)
    again = record(params.merge("outcome" => 2, "reasons" => []))
    expect(again).to be_ok
    expect(again.payload).to include(replayed: true)
    expect(again.payload[:visit].id).to eq(first.payload[:visit].id)
    expect(again.payload[:day].id).to eq(first.payload[:day].id)
    expect(again.payload[:visit].outcome).to eq(1)
    expect(HomeVisit.count).to eq(1)
    expect(recorded_events.count).to eq(1)
    other = field_agent!(team: team)
    expect(failure(record(params, by: other))).to eq([ :client_uuid_conflict, "client_uuid" ])
    expect(failure(record(params.merge("client_uuid" => "x")))).to eq([ :invalid_request, "client_uuid" ])
  end

  it "o evento só tem os três ids (nunca motivo, medida, observação ou pessoa)" do
    patient = registry_patient!
    result = record(body(subject: "resident", patient_id: patient.id, reasons: [ 11 ], note: "pressão alta, chamar a filha",
                         measurements: { "systolic" => 150, "diastolic" => 95 }))
    expect(result).to be_ok
    expect(recorded_events.sole.payload).to eq("home_visit_id" => result.payload[:visit].id,
                                                "home_visit_day_id" => result.payload[:day].id, "user_id" => acs.id)
  end

  it "a 100ª visita não retirada fecha a folha cheia (closed_by full, ficha gerada) e abre a 2" do
    full = home_visit_day!(agent: acs, team: team)
    98.times { home_visit!(day: full, micro_area: area) }
    home_visit!(day: full, micro_area: area, withdrawn_at: Time.current, withdrawn_by_user: acs, withdrawal_reason: "lançada errada")
    ninety_ninth = record
    expect(ninety_ninth.payload[:day].id).to eq(full.id)
    expect(full.reload.state).to eq("open")

    hundredth = record
    expect(hundredth).to be_ok
    expect(full.reload).to have_attributes(state: "closed", closed_by: "full", closed_by_user_id: nil)
    expect(full.home_visits.valid.count).to eq(99)
    expect(entries_of(full).sole).to have_attributes(status: "pending", ficha_type: "visita_domiciliar")
    expect(DomainEvent.where(name: "home_visit_day.closed").sole.payload).to eq("home_visit_day_id" => full.id, "closed_by" => "full")
    nxt = hundredth.payload[:day]
    expect(nxt).to have_attributes(sequence: 2, state: "open", day: today, cbo: HomeVisits::Catalog::ACS_CBO)
    expect(hundredth.payload[:visit].home_visit_day_id).to eq(nxt.id)
  end

  it "recusa das regras na 100ª não fecha a folha nem gera ficha (regras antes de qualquer escrita)" do
    full = home_visit_day!(agent: acs, team: team)
    99.times { home_visit!(day: full, micro_area: area) }
    expect(failure(record(body(reasons: [ 11 ])))).to eq([ :reason_not_allowed, "reasons[0]" ])
    expect(full.reload.state).to eq("open")
    expect(entries_of(full)).to be_empty
    expect(HomeVisitDay.count).to eq(1)
    expect(recorded_events).to be_empty
  end

  it "visita para dia de folha fechada abre a complementar (sequence seguinte, inclusive em dia anterior)" do
    closed = home_visit_day!(agent: acs, team: team, state: "closed")
    result = record
    expect(result.payload[:day]).to have_attributes(sequence: 2, state: "open")
    expect(closed.reload.state).to eq("closed")

    yesterday = (today - 1).in_time_zone.change(hour: 15)
    home_visit_day!(agent: acs, team: team, day: today - 1, state: "closed")
    home_visit_day!(agent: acs, team: team, day: today - 1, sequence: 2, state: "closed")
    back = record(body(occurred_at: yesterday.iso8601))
    expect(back.payload[:day]).to have_attributes(day: today - 1, sequence: 3, state: "open")
    expect(back.payload[:visit].shift).to eq(2)
  end

  it "fora de área pelo ACS grava micro_area nula; pelo TACS → out_of_scope" do
    result = record(body(micro_area_id: nil, out_of_area: true))
    expect(result).to be_ok
    expect(result.payload[:visit]).to have_attributes(micro_area_id: nil, out_of_area: true)
    tacs = field_agent!(cbo: "322255", team: team)
    assignment!(area, tacs.professional)
    expect(failure(record(body(micro_area_id: nil, out_of_area: true), by: tacs))).to eq([ :out_of_scope, nil ])
  end

  it "escopo e acesso: enfermeiro → cbo_not_allowed; outra equipe, microárea alheia → out_of_scope; domicílio de outra equipe → not_found" do
    nurse = registry_nurse!(team.health_unit, team: team)
    expect(record(by: nurse).reason).to eq(:cbo_not_allowed)
    expect(record(body(team_id: registry_team!.id)).reason).to eq(:out_of_scope)
    other_area = registry_micro_area!(code: "02", team: team, acs: field_agent!(team: team))
    expect(record(body(micro_area_id: other_area.id)).reason).to eq(:out_of_scope)
    foreign = registry_household!(micro_area: registry_micro_area!(code: "03", team: registry_team!))
    expect(failure(record(household_body(foreign)))).to eq([ :not_found, "household_id" ])
    expect(failure(record(body(micro_area_id: SecureRandom.uuid)))).to eq([ :not_found, "micro_area_id" ])
    expect(HomeVisit.count).to eq(0)
    expect(HomeVisitDay.count).to eq(0)
  end

  it "com domicílio herda tipo de imóvel e microárea; domicílio inativo → household_inactive" do
    household = registry_household!(micro_area: area)
    result = record(household_body(household))
    expect(result.payload[:visit]).to have_attributes(household_id: household.id, micro_area_id: area.id, property_type: "1")
    household.update!(status: "inactive")
    expect(failure(record(household_body(household)))).to eq([ :household_inactive, "household_id" ])
    area.update!(active: false)
    expect(failure(record(body))).to eq([ :micro_area_inactive, "micro_area_id" ])
  end

  it "registro rápido com duplicado → duplicate_suspected e nada gravado; a trilha dos candidatos fica" do
    existing = registry_patient!
    typed = { "full_name" => existing.full_name, "birth_date" => existing.birth_date, "sex" => "female", "no_cpf_reason" => "3" }
    result = nil
    expect { result = record(body(subject: "resident", new_patient: typed, reasons: [ 11 ])) }
      .not_to change { [ Patient.count, HomeVisit.count, HomeVisitDay.count ] }
    expect(failure(result)).to eq([ :duplicate_suspected, "new_patient" ])
    expect(result.details[:candidates].map { _1[:patient_id] }).to include(existing.id)
    expect(recorded_events).to be_empty
    viewed = DomainEvent.where(name: "clinical_record.viewed").map(&:payload)
    expect(viewed).to include(include("patient_id" => existing.id, "user_id" => acs.id, "access" => "home_visits"))

    reviewed = record(body(subject: "resident", new_patient: typed, duplicates_reviewed: true, reasons: [ 11 ]))
    expect(reviewed).to be_ok
    expect(reviewed.payload[:visit].patient).to have_attributes(full_name: existing.full_name, sex: "female")
    expect(reviewed.payload[:visit].subject).to eq("resident")
  end

  it "registro rápido inválido → invalid_patient com o path do campo (Q49), nada gravado" do
    typed = { "full_name" => "Ana", "birth_date" => "2090-01-01", "sex" => "female", "no_cpf_reason" => "3" }
    result = record(body(subject: "resident", new_patient: typed))
    expect(result.reason).to eq(:invalid_patient)
    expect(result.details[:path]).to start_with("new_patient.")
    expect(HomeVisitDay.count).to eq(0)
  end

  it "paciente por patient_id: provisório da UPA → patient_unidentified; cadastro ativo em outro domicílio → patient_in_other_household" do
    provisional = Patient.create!(no_cpf_reason: "unidentified", unidentified: true, unidentified_description: "homem idoso")
    expect(failure(record(body(subject: "resident", patient_id: provisional.id)))).to eq([ :patient_unidentified, "patient_id" ])
    household = registry_household!(micro_area: area)
    elsewhere = registry_registration!(household: registry_household!(micro_area: area)).patient
    expect(failure(record(household_body(household, subject: "resident", patient_id: elsewhere.id))))
      .to eq([ :patient_in_other_household, "patient_id" ])
    here = registry_registration!(household: household).patient
    expect(record(household_body(household, subject: "resident", patient_id: here.id, reasons: [ 11 ]))).to be_ok
    expect(record(household_body(household, subject: "resident", patient_id: registry_patient!.id, reasons: [ 11 ]))).to be_ok
  end

  it "masculino com motivo 5 → reason_not_allowed (o sexo do paciente gravado)" do
    patient = registry_patient!.tap { _1.update!(sex: "male") }
    expect(failure(record(body(subject: "resident", patient_id: patient.id, reasons: [ 5 ])))).to eq([ :reason_not_allowed, "reasons[0]" ])
  end

  it "family_responsible grava o responsável em patient_id; família em mudança → family_moved_out" do
    household = registry_household!(micro_area: area)
    responsible = registry_patient!
    family = registry_family!(household, responsible: responsible)
    result = record(household_body(household, subject: "family_responsible", family_id: family.id, reasons: [ 29 ]))
    expect(result).to be_ok
    expect(result.payload[:visit]).to have_attributes(subject: "family_responsible", family_id: family.id, patient_id: responsible.id)
    other = registry_household!(micro_area: area)
    expect(failure(record(household_body(other, subject: "family_responsible", family_id: family.id)))).to eq([ :not_found, "family_id" ])
    family.update!(moved_out: true)
    expect(failure(record(household_body(household, subject: "family_responsible", family_id: family.id))))
      .to eq([ :family_moved_out, "family_id" ])
  end

  it "responsável que saiu → family_without_responsible; responsável provisório da UPA → patient_unidentified" do
    household = registry_household!(micro_area: area)
    registration = registry_registration!(household: household)
    family = Family.create!(household: household, responsible_patient: registration.patient, moved_out: false)
    registration.update_columns(exit_reason: "moved", exited_on: today)
    expect(failure(record(household_body(household, subject: "family_responsible", family_id: family.id))))
      .to eq([ :family_without_responsible, "family_id" ])

    provisional = Patient.create!(no_cpf_reason: "unidentified", unidentified: true, unidentified_description: "mulher jovem")
    odd = Family.create!(household: registry_household!(micro_area: area), responsible_patient: provisional, moved_out: false)
    expect(failure(record(household_body(odd.household, subject: "family_responsible", family_id: odd.id))))
      .to eq([ :patient_unidentified, "patient_id" ])
  end

  it "morador que não é o responsável, com motivo 29/34–37, vira family_responsible da família dele (Q43)" do
    household = registry_household!(micro_area: area)
    responsible = registry_patient!
    family = registry_family!(household, responsible: responsible)
    resident = registry_registration!(household: household)
    resident.update_columns(family_id: family.id)
    result = record(household_body(household, subject: "resident", patient_id: resident.patient_id, reasons: [ 35, 1 ]))
    expect(result).to be_ok
    expect(result.payload[:visit]).to have_attributes(subject: "family_responsible", family_id: family.id, patient_id: responsible.id)
    plain = record(household_body(household, subject: "resident", patient_id: resident.patient_id, reasons: [ 11 ]))
    expect(plain.payload[:visit]).to have_attributes(subject: "resident", family_id: nil, patient_id: resident.patient_id)
  end

  it "sem pessoa com 29/34–37: recusado com família ativa no domicílio, aceito sem família (Q40, Q44)" do
    household = registry_household!(micro_area: area)
    expect(record(household_body(household, reasons: [ 34 ]))).to be_ok
    registry_family!(household)
    expect(failure(record(household_body(household, reasons: [ 34 ])))).to eq([ :reason_not_allowed, "reasons[0]" ])
  end

  it "medidas arredondadas pelas casas do YAML antes de gravar; app de campo grava o aparelho" do
    patient = registry_patient!
    result = record(body(subject: "resident", patient_id: patient.id, reasons: [ 11 ],
                         measurements: { "weight_kg" => 70.12345, "height_cm" => 160.06, "temperature_c" => 36.56 }))
    expect(result.payload[:visit].reload.measurements).to eq("weight_kg" => 70.123, "height_cm" => 160.1, "temperature_c" => 36.6)
    expect { record(origin: "field_app") }.to raise_error(ArgumentError)
    expect { record(origin: "sms") }.to raise_error(ArgumentError)
  end

  it "o Result de recusa não leva motivo, observação nem documento" do
    result = record(body(subject: "resident", new_patient: { "full_name" => "Ana Souza", "birth_date" => "1990-01-01", "sex" => "female",
                                                             "cpf" => "111" }, note: "segredo da casa"))
    text = [ result.inspect, result.details.inspect ].join
    expect(text).not_to include("Ana Souza", "segredo", "111")
  end
end

# Review Focus 1 (plano, Task 8; contrato §2, Q6; pre-flight 1.8): visitas
# gravadas ao mesmo tempo pelo mesmo profissional no mesmo dia. A primeira grava
# e fica parada antes do commit; a segunda espera na trava consultiva por
# (profissional, equipe, dia). Na folha com 98, a 99ª entra na folha 1 e a 100ª
# fecha a folha 1 cheia (99 visitas, ficha montada) e abre a 2. Sem folha, as
# duas primeiras do dia não abrem duas folhas (o índice parcial "uma aberta"
# nunca dispara). Threads reais contra TEST_CITY_A, sem fixture transacional (o
# padrão do withdraw_spec.rb: fila `go`, pop(timeout:) e limpeza no after).
RSpec.describe HomeVisits::Record, "× visitas simultâneas (concorrência)" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let(:fichas) { Queue.new }

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  def snapshot
    connection = ApplicationRecord.connection
    connection.tables.select { |table| connection.column_exists?(table, :id) }
              .to_h { |table| [ table, connection.select_values("SELECT id::text FROM #{connection.quote_table_name(table)}").to_set ] }
  end

  before do
    @before = in_city { snapshot }
    @ids = in_city do
      team = registry_team!
      { agent: field_agent!(team: team).id, team: team.id }
    end
    allow(Ledi::HomeVisitDayFicha).to receive(:exportable?).and_return(true)
    allow(Ledi::HomeVisitDayFicha).to receive(:profile_incomplete?).and_return(false)
    allow(Ledi::Enqueue).to receive(:call) { |ficha, **| fichas << ficha }
  end

  after do
    3.times { release << true }
    threads.each do |thread|
      thread.join(5) || thread.kill
    rescue StandardError
      nil # join relança a exceção da thread; o exemplo já falhou e a limpeza precisa rodar
    end
    in_city do
      ApplicationRecord.transaction do
        connection = ApplicationRecord.connection
        connection.execute("SET LOCAL session_replication_role = replica")
        snapshot.each do |table, ids|
          fresh = ids - @before.fetch(table, Set.new)
          next if fresh.empty?

          connection.execute("DELETE FROM #{connection.quote_table_name(table)} WHERE id::text IN (#{fresh.map { connection.quote(_1) }.join(',')})")
        end
      end
    end
  end

  def visit_now(go)
    go.pop(timeout: 5) or raise "timeout esperando go"
    in_city do
      described_class.call(params: { "client_uuid" => SecureRandom.uuid, "team_id" => @ids[:team],
                                     "occurred_at" => Time.current.change(usec: 0).iso8601, "out_of_area" => true,
                                     "property_type" => "1", "subject" => "none", "outcome" => 1, "reasons" => [ 1 ] },
                           by: User.find(@ids[:agent]))
    end
  rescue StandardError => e
    e
  end

  # A primeira grava e para antes do commit; a segunda tem de esperar numa
  # trava. -> [primeira, segunda]
  def race
    holder = nil
    holding = Queue.new
    original = DomainEvents.method(:publish)
    allow(DomainEvents).to receive(:publish) do |*args, **kwargs, &blk|
      result = original.call(*args, **kwargs, &blk)
      if Thread.current == holder && args.first == "home_visit.recorded"
        holding << true
        release.pop(timeout: 10) or raise "timeout esperando release"
      end
      result
    end

    go_first = Queue.new
    first_result = Queue.new
    threads << (holder = Thread.new { first_result << visit_now(go_first) })
    go_first << true
    holding.pop(timeout: 5) or raise "a primeira não chegou a gravar"

    go_second = Queue.new
    second_result = Queue.new
    threads << (other = Thread.new { second_result << visit_now(go_second) })
    go_second << true
    expect(wait_for_lock_wait).to be(true) # a segunda espera a trava da folha

    release << true
    expect(holder.join(10)).to be(holder)
    expect(other.join(10)).to be(other)
    results = [ first_result.pop(timeout: 1), second_result.pop(timeout: 1) ]
    expect(results).to all(be_a(Result)) # nenhuma exceção (RecordNotUnique, deadlock)
    expect(results).to all(be_ok)
    results
  end

  it "a 99ª e a 100ª: uma folha full com 99 visitas e a outra visita na sequence 2" do
    @ids[:day] = in_city do
      agent = User.find(@ids[:agent])
      day = home_visit_day!(agent: agent, team: HealthTeam.find(@ids[:team]))
      98.times { home_visit!(day: day) }
      day.id
    end

    first, second = race
    expect(first.payload[:day].id).to eq(@ids[:day])
    expect(fichas.pop(timeout: 1).visits.size).to eq(99)
    in_city do
      sheet = HomeVisitDay.find(@ids[:day])
      expect(sheet).to have_attributes(state: "closed", closed_by: "full")
      expect(sheet.home_visits.count).to eq(99)
      nxt = HomeVisitDay.find(second.payload[:day].id)
      expect(nxt).to have_attributes(sequence: 2, state: "open", professional_id: sheet.professional_id, team_id: sheet.team_id)
      expect(nxt.home_visits.pluck(:id)).to eq([ second.payload[:visit].id ])
    end
  end

  it "as duas primeiras do dia: uma folha só (sequence 1) com as duas visitas" do
    first, second = race
    expect(second.payload[:day].id).to eq(first.payload[:day].id)
    in_city do
      days = HomeVisitDay.where(user_id: @ids[:agent])
      expect(days.pluck(:sequence, :state)).to eq([ [ 1, "open" ] ])
      expect(days.sole.home_visits.count).to eq(2)
    end
  end
end
