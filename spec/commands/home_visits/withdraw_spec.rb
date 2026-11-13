require "rails_helper"

# Módulo 24b (ADR 0052; contrato §2, §13; Q45 da coordenação; plano, Task 10 e
# Review Focus 2): a retirada da visita. Só o dono da folha, com a folha aberta,
# uma vez; motivo de 10–500 (cifrado, nunca no evento nem no erro); a linha só
# ganha os três campos de retirada. Já retirada → 409 visit_changed; folha
# fechada → 409 day_closed; outro usuário → not_found. As folhas e as visitas
# nascem direto nas linhas (Ruling A7: antes do HomeVisits::Record).
RSpec.describe HomeVisits::Withdraw, type: :model do
  before { home_visit_city! }

  let(:team) { registry_team! }
  let(:agent) { field_agent!(team: team) }
  let(:area) { registry_micro_area!(code: "01", team: team, acs: agent) }
  let(:day) { home_visit_day!(agent: agent, team: team) }
  let(:visit) { home_visit!(day: day, micro_area: area, subject: "resident", patient: registry_patient!) }
  let(:reason) { "Lançada para o morador errado" }

  def withdraw(target = visit, by: agent, expected_state: "recorded", why: reason) =
    described_class.call(target, by: by, expected_state: expected_state, reason: why)

  def withdrawn_events = DomainEvent.where(name: "home_visit.withdrawn")

  it "retira com motivo de 10–500 → withdrawn e evento só com ids" do
    before = visit.reload.attributes.except("withdrawn_at", "withdrawn_by_user_id", "withdrawal_reason")
    result = withdraw(why: "  #{reason}  ")
    expect(result).to be_ok
    stored = HomeVisit.find(visit.id)
    expect(stored).to have_attributes(withdrawn_by_user_id: agent.id, withdrawal_reason: reason)
    expect(stored.withdrawn_at).to be_present
    expect(stored.attributes.except("withdrawn_at", "withdrawn_by_user_id", "withdrawal_reason")).to eq(before)
    expect(result.payload[:visit]).to be_withdrawn
    event = withdrawn_events.sole
    expect(event.payload).to eq("home_visit_id" => visit.id, "home_visit_day_id" => day.id, "user_id" => agent.id)
    expect([ event.payload.to_s, result.inspect ].join).not_to include("morador errado")
    expect(HomeVisits::Json.day(day.reload)).to include(visits_count: 0, withdrawn_count: 1)
  end

  it "10 e 500 passam; 9, 501, vazio e não-texto → invalid_request path reason, nada gravado" do
    expect(withdraw(why: "a" * 10)).to be_ok
    other = home_visit!(day: day, micro_area: area)
    expect(withdraw(other, why: "é" * 500)).to be_ok
    [ "a" * 9, "a" * 501, "   ", nil, 1234567890 ].each do |bad|
      target = home_visit!(day: day, micro_area: area)
      result = withdraw(target, why: bad)
      expect([ result.reason, result.details ]).to eq([ :invalid_request, { path: "reason" } ])
      expect(target.reload).not_to be_withdrawn
    end
    expect(withdrawn_events.count).to eq(2)
  end

  it "já retirada → visit_changed, sem segundo evento" do
    expect(withdraw).to be_ok
    expect(withdraw(HomeVisit.find(visit.id)).reason).to eq(:visit_changed)
    expect(withdrawn_events.count).to eq(1)
  end

  it "expected_state withdrawn numa gravada → visit_changed; inválido → invalid_request path expected_state" do
    expect(withdraw(expected_state: "withdrawn").reason).to eq(:visit_changed)
    invalid = withdraw(expected_state: "gone")
    expect([ invalid.reason, invalid.details ]).to eq([ :invalid_request, { path: "expected_state" } ])
    expect(visit.reload).not_to be_withdrawn
  end

  it "folha fechada → day_closed" do
    visit
    expect(HomeVisits::CloseDay.call(day, by: agent, closed_by: "user")).to be_ok
    expect(withdraw(HomeVisit.find(visit.id)).reason).to eq(:day_closed)
    expect(visit.reload).not_to be_withdrawn
    expect(withdrawn_events).to be_empty
  end

  it "outro usuário (até o enfermeiro da equipe) → not_found" do
    expect(withdraw(by: field_agent!(team: team)).reason).to eq(:not_found)
    expect(withdraw(by: registry_nurse!(team.health_unit, team: team)).reason).to eq(:not_found)
    expect(visit.reload).not_to be_withdrawn
  end
end

# Review Focus 2 (plano; contrato §2): o dono retira enquanto o job fecha a
# folha. Os dois comandos travam a folha FOR UPDATE (a retirada: folha →
# visita); quem chega depois espera. Ou a retirada entra antes (a ficha sai sem
# a visita) ou recebe 409 day_closed (a visita fica e vai na ficha); a ficha
# nunca leva visita retirada. Threads reais contra TEST_CITY_A, sem fixture
# transacional (padrão de spec/commands/territory_registry/locks_spec.rb e do
# módulo 09: pop(timeout:) e limpeza no after). A plataforma não é tocada: a
# exportação utilizável e o perfil completo são simulados no módulo da ficha, e
# o Ledi::Enqueue só guarda a ficha montada (a montagem é a real).
RSpec.describe HomeVisits::Withdraw, "× fechamento (concorrência)" do
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
      agent = field_agent!(team: team)
      day = home_visit_day!(agent: agent, team: team)
      kept = home_visit!(day: day, occurred_at: Time.zone.today.in_time_zone.change(hour: 8), outcome: 3)
      target = home_visit!(day: day, occurred_at: Time.zone.today.in_time_zone.change(hour: 9), outcome: 1)
      { agent: agent.id, day: day.id, kept: kept.id, target: target.id }
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

  def capture
    yield
  rescue StandardError => e
    e
  end

  def withdraw
    capture do
      in_city do
        described_class.call(HomeVisit.find(@ids[:target]), by: User.find(@ids[:agent]), expected_state: "recorded",
                                                            reason: "Lançada para o imóvel errado")
      end
    end
  end

  def close = capture { in_city { HomeVisits::CloseDay.call(HomeVisitDay.find(@ids[:day]), by: nil, closed_by: "job") } }

  # A primeira (`first`) grava, publica `event` e fica parada antes do commit;
  # a segunda tem de esperar na trava da folha. -> [primeira, segunda]
  def race(first, event, second)
    holding = Queue.new
    holder = nil
    original = DomainEvents.method(:publish)
    allow(DomainEvents).to receive(:publish) do |*args, **kwargs, &blk|
      result = original.call(*args, **kwargs, &blk)
      if Thread.current == holder && args.first == event
        holding << true
        release.pop(timeout: 10) or raise "timeout esperando release"
      end
      result
    end

    first_result = Queue.new
    threads << (holder = Thread.new { first_result << send(first) })
    holding.pop(timeout: 5) or raise "a primeira não chegou a gravar"

    second_result = Queue.new
    threads << (other = Thread.new { second_result << send(second) })
    expect(wait_for_lock_wait).to be(true) # a segunda espera na trava da folha

    release << true
    expect(holder.join(10)).to be(holder)
    expect(other.join(10)).to be(other)
    results = [ first_result.pop(timeout: 1), second_result.pop(timeout: 1) ]
    expect(results).to all(be_a(Result)) # nenhuma exceção (deadlock inclusive)
    results
  end

  def ficha_outcomes = fichas.pop(timeout: 1).visits.map { |row| row["outcome"] }

  it "a retirada entra antes: o fechamento espera e a ficha sai sem a visita retirada" do
    withdrawn, closed = race(:withdraw, "home_visit.withdrawn", :close)
    expect([ withdrawn.ok?, closed.ok? ]).to eq([ true, true ])
    expect(ficha_outcomes).to eq([ 3 ])
    expect(fichas).to be_empty
    in_city do
      expect(HomeVisit.find(@ids[:target])).to be_withdrawn
      expect(HomeVisitDay.find(@ids[:day])).to have_attributes(state: "closed", closed_by: "job")
    end
  end

  it "o fechamento entra antes: a retirada espera e recebe day_closed; a visita fica e vai na ficha" do
    closed, withdrawn = race(:close, "home_visit_day.closed", :withdraw)
    expect(closed).to be_ok
    expect(withdrawn.reason).to eq(:day_closed)
    expect(ficha_outcomes).to eq([ 3, 1 ])
    in_city do
      expect(HomeVisit.find(@ids[:target])).not_to be_withdrawn
      expect(DomainEvent.where(name: "home_visit.withdrawn").where("payload ->> 'home_visit_id' = ?", @ids[:target])).to be_empty
    end
  end
end
