require "rails_helper"

# Módulo 24b (ADR 0052; contrato §2, §6, §10; Q5, Q12; plano, Task 10, Desvio 3
# e W-11): o fechamento da folha do dia. open → closed uma vez (409 day_changed
# na segunda), pelo dono (closed_by user), pelo job ou cheia (sem usuário); a
# ficha 8 nasce DENTRO da transação do fechamento; prazo do SIAPS vencido fecha
# com "não gerada" siaps_deadline_passed e nunca descarta; exportação desligada
# → ficha.status not_exported. "Reenviar" a recusada regera da folha pelo
# Ledi::Resend (o mesmo do /production), e a folha não muda. As folhas e as
# visitas nascem direto nas linhas (Ruling A7: antes do HomeVisits::Record).
RSpec.describe HomeVisits::CloseDay, type: :model do
  let!(:city) { home_visit_city! }
  let(:team) { registry_team! }
  let(:agent) { field_agent!(team: team) }
  let(:area) { registry_micro_area!(code: "01", team: team, acs: agent) }
  let(:today) { Time.zone.today }

  before { allow(Ledi::DeliverJob).to receive(:perform_later) }

  def entries_of(day) = LediOutboxEntry.where(source_type: "HomeVisitDay", source_id: day.id).order(:created_at, :id)
  def failure_of(day) = LediGenerationFailure.find_by(source_type: "HomeVisitDay", source_id: day.id)
  def closed_events = DomainEvent.where(name: "home_visit_day.closed")
  def close(day, by: agent, closed_by: "user", **opts) = HomeVisits::CloseDay.call(day, by: by, closed_by: closed_by, **opts)
  def withdraw!(visit) = visit.update!(withdrawn_at: Time.current, withdrawn_by_user: agent, withdrawal_reason: "lançada na folha errada")

  it "o dono fecha com expected_state open → ficha pending no outbox, um evento só com ids" do
    day = home_visit_day!(agent: agent, team: team)
    home_visit!(day: day, micro_area: area, subject: "resident", patient: registry_patient!, reasons: [ 11 ], has_reason: true)
    expect(HomeVisits::Json.day(day.reload)[:ficha]).to eq(status: "open", reasons: [])

    result = close(day, expected_state: "open")
    expect(result).to be_ok
    expect(result.payload[:day].reload).to have_attributes(state: "closed", closed_by: "user", closed_by_user_id: agent.id)
    expect(result.payload[:day].closed_at).to be_present
    expect(entries_of(day).sole).to have_attributes(status: "pending", ficha_type: "visita_domiciliar")
    expect(closed_events.sole.payload).to eq("home_visit_day_id" => day.id, "closed_by" => "user")
    expect(HomeVisits::Json.day(day.reload)[:ficha]).to eq(status: "pending", reasons: [])
  end

  it "segunda vez → day_changed, sem segunda ficha nem segundo evento" do
    day = home_visit_day!(agent: agent, team: team)
    home_visit!(day: day, micro_area: area)
    expect(close(day)).to be_ok
    second = close(HomeVisitDay.find(day.id))
    expect(second.reason).to eq(:day_changed)
    expect(entries_of(day).count).to eq(1)
    expect(closed_events.count).to eq(1)
  end

  it "expected_state diferente de open → day_changed sem fechar; inválido → invalid_request path expected_state" do
    day = home_visit_day!(agent: agent, team: team)
    home_visit!(day: day, micro_area: area)
    expect(close(day, expected_state: "closed").reason).to eq(:day_changed)
    invalid = close(day, expected_state: "fechada")
    expect([ invalid.reason, invalid.details ]).to eq([ :invalid_request, { path: "expected_state" } ])
    expect(close(day, expected_state: nil).reason).to eq(:invalid_request)
    expect(day.reload.state).to eq("open")
    expect(closed_events).to be_empty
  end

  it "outro usuário → not_found, nada gravado" do
    day = home_visit_day!(agent: agent, team: team)
    home_visit!(day: day, micro_area: area)
    expect(close(day, by: field_agent!(team: team)).reason).to eq(:not_found)
    expect(day.reload.state).to eq("open")
    expect(entries_of(day)).to be_empty
  end

  it "o job e a folha cheia fecham sem usuário (closed_by job | full, closed_by_user nulo)" do
    job_day = home_visit_day!(agent: agent, team: team, day: today - 1)
    home_visit!(day: job_day, micro_area: area)
    expect(close(job_day, by: nil, closed_by: "job")).to be_ok
    expect(job_day.reload).to have_attributes(state: "closed", closed_by: "job", closed_by_user_id: nil)
    full_day = home_visit_day!(agent: agent, team: team)
    home_visit!(day: full_day, micro_area: area)
    expect(close(full_day, by: nil, closed_by: "full")).to be_ok
    expect(full_day.reload.closed_by).to eq("full")
    expect(closed_events.map(&:payload).map { |row| row["closed_by"] }).to contain_exactly("job", "full")
    expect { close(home_visit_day!(agent: field_agent!(team: team), team: team), by: nil, closed_by: "user") }.to raise_error(ArgumentError)
    expect { close(home_visit_day!(agent: field_agent!(team: team), team: team), closed_by: "other") }.to raise_error(ArgumentError)
  end

  it "prazo do SIAPS vencido fecha com não gerada siaps_deadline_passed; nunca descarta" do
    past = today.prev_month(3)
    day = home_visit_day!(agent: agent, team: team, day: past)
    home_visit!(day: day, micro_area: area, occurred_at: past.in_time_zone.change(hour: 10))
    expect(HomeVisits::Blockers.for(day)).to eq([ { code: "siaps_deadline_passed", visit_id: nil } ])

    expect(close(day, by: nil, closed_by: "job")).to be_ok
    expect(day.reload.state).to eq("closed")
    expect(HomeVisit.where(home_visit_day_id: day.id).count).to eq(1)
    expect(failure_of(day).reason_codes).to eq(%w[siaps_deadline_passed])
    expect(entries_of(day)).to be_empty
    json = HomeVisits::Json.day(day)
    expect(json[:ficha]).to eq(status: "not_generated", reasons: %w[siaps_deadline_passed])
    expect(json[:blockers]).to eq([])
  end

  it "retry! de siaps_deadline_passed (Gerar de novo pela Produção) segue não gerada (W-11)" do
    past = today.prev_month(3)
    day = home_visit_day!(agent: agent, team: team, day: past)
    home_visit!(day: day, micro_area: area, occurred_at: past.in_time_zone.change(hour: 10))
    close(day, by: nil, closed_by: "job")
    failure = failure_of(day)
    retried = Ledi::FichaSources.for(failure.source_type).retry!(failure, by: care_admin!)
    expect(retried.resolved?).to be(false)
    expect(retried.reason_codes).to eq(%w[siaps_deadline_passed])
    expect(entries_of(day)).to be_empty
    expect(HomeVisits::Json.day(day.reload)[:ficha]).to eq(status: "not_generated", reasons: %w[siaps_deadline_passed])
  end

  it "exportação desligada → fecha sem ficha e sem falha: not_exported (Desvio 3, Q5)" do
    ledi_off!(city)
    CityCatalog.reset_cache!
    day = home_visit_day!(agent: agent, team: team)
    home_visit!(day: day, micro_area: area)
    expect(close(day)).to be_ok
    expect(day.reload.state).to eq("closed")
    expect(entries_of(day)).to be_empty
    expect(failure_of(day)).to be_nil
    expect(HomeVisits::Json.day(day)[:ficha]).to eq(status: "not_exported", reasons: [])
    expect(HomeVisits::Json.day(day)[:ledi_export_enabled]).to be(false) # Q50
  end

  it "folha só com retiradas → fecha sem ficha nem falha: empty" do
    day = home_visit_day!(agent: agent, team: team)
    withdraw!(home_visit!(day: day, micro_area: area))
    expect(close(day)).to be_ok
    expect(entries_of(day)).to be_empty
    expect(failure_of(day)).to be_nil
    expect(HomeVisits::Json.day(day.reload)[:ficha]).to eq(status: "empty", reasons: [])
  end

  it "ficha recusada: Reenviar (Ledi::Resend, o do /production) regera da folha com uuid novo e replaces_outbox_id; a folha não muda" do
    day = home_visit_day!(agent: agent, team: team)
    home_visit!(day: day, micro_area: area)
    close(day)
    rejected = entries_of(day).sole
    rejected.update!(status: "sending")
    rejected.reject!([ Ledi::ErrorCodes::UNKNOWN.dup ])
    expect(HomeVisits::Json.day(day.reload)[:ficha]).to eq(status: "rejected", reasons: [])
    before = day.reload.attributes

    fresh = Ledi::Resend.call(entry: rejected.reload, by: care_admin!)
    expect(fresh).to have_attributes(source_type: "HomeVisitDay", source_id: day.id, replaces_outbox_id: rejected.id, status: "pending")
    expect(fresh.uuid).not_to eq(rejected.uuid)
    expect(day.reload.attributes).to eq(before)
    expect(HomeVisits::Json.day(day)[:ficha]).to eq(status: "pending", reasons: [])
  end

  describe HomeVisits::Json, ".day" do
    it "forma do §6: contagens, own, situação da ficha e blockers só com a folha aberta" do
      day = home_visit_day!(agent: agent, team: team)
      provisional = Patient.create!(unidentified: true, no_cpf_reason: "unidentified", unidentified_description: "senhor de boné",
                                    birth_date: "1950-01-01", sex: "male")
      home_visit!(day: day, micro_area: area, occurred_at: today.in_time_zone.change(hour: 8))
      visit = home_visit!(day: day, micro_area: area, occurred_at: today.in_time_zone.change(hour: 9), subject: "resident",
                          patient: provisional)
      withdraw!(home_visit!(day: day, micro_area: area, occurred_at: today.in_time_zone.change(hour: 10)))

      json = HomeVisits::Json.day(day.reload, viewer: agent)
      expect(json).to eq(
        id: day.id, professional: { id: agent.professional.id, name: agent.professional.professional_name },
        team: { id: team.id, ine: team.ine, name: team.name }, day: today.iso8601, sequence: 1, state: "open",
        closed_at: nil, closed_by: nil, visits_count: 2, withdrawn_count: 1, own: true,
        ficha: { status: "open", reasons: [] }, blockers: [ { code: "patient_without_identifier", visit_id: visit.id } ],
        ledi_export_enabled: true
      )
      expect(HomeVisits::Blockers.for(day)).to eq(json[:blockers])
      expect(HomeVisits::Json.day(day, viewer: registry_nurse!(team.health_unit, team: team))[:own]).to be(false)
      expect(HomeVisits::Json.day(day)[:own]).to be(false)
      expect(LediGenerationFailure.where(source_type: "HomeVisitDay")).to be_empty # blockers não gravam

      close(day)
      closed = HomeVisits::Json.day(day.reload, viewer: agent)
      expect(closed).to include(state: "closed", closed_by: "user", closed_at: day.closed_at.iso8601, blockers: [],
                                ficha: { status: "not_generated", reasons: %w[patient_without_identifier] })
    end
  end
end
