require "rails_helper"

# Módulo 24b, Task 16 (contrato §12; Q10/A-12; plano, Desvio 7): com `home_visits`
# utilizável, a visita domiciliar realizada vira a fonte `acs_visit` (com motivo,
# imóvel residencial, folha do ACS 515105 ou do TACS 322255, não retirada) e a
# medida da visita (qualquer CBO da Tabela 7) entra em `blood_pressure` e
# `weight_height`. Sem o interruptor, a visita não entra em fonte nenhuma.
RSpec.describe "CareLines: visita domiciliar como fonte", type: :model do
  before { home_visit_city! }

  let(:today) { Time.zone.today }
  let(:patient) { registry_patient! }
  let(:acs) { field_agent!(cbo: HomeVisits::Catalog::ACS_CBO) }
  let(:entries) { CareLines::Templates::Load.entries.index_by { |e| e["key"] } }

  def practices(key) = CareLines::Rules.practices(entries.fetch(key)["practices"], template: true).payload[:practices]

  def visit!(agent: acs, days_ago: 10, who: patient, **over)
    day = HomeVisitDay.find_by(user: agent, day: today - days_ago) || home_visit_day!(agent: agent, day: today - days_ago)
    home_visit!(day: day, subject: "resident", patient: who, has_reason: true, **over)
  end

  def load(sources = %w[acs_visit blood_pressure weight_height], home_visits: true, ids: [ patient.id ])
    CareLines::Sources.load(patient_ids: ids, sources: sources, since: today - 365, home_visits: home_visits)
  end

  def events(sources = %w[acs_visit blood_pressure weight_height], **opts) = load(sources, **opts).fetch(patient.id, {})

  def c5_d(who: patient, **opts)
    person = CareLines::Person.new(patient_id: who.id, birth_date: today - 20_000, sex: "female")
    item = { key: "p", practices: practices("hypertension_c5"), person: person, anchors: {} }
    CareLines::Evaluation.items([ item ], today: today, **opts).fetch("p").practices.find { |s| s.key == "c5_d" }
  end

  it "sem home_visits a prática acs_visit é untracked" do
    visit!
    expect(CareLines::Catalog.untracked?("acs_visit")).to be(true)
    expect(CareLines::Catalog.untracked?("acs_visit", home_visits: false)).to be(true)
    expect(CareLines::Catalog.untracked?("acs_visit", home_visits: true)).to be(false)
    expect(c5_d).to have_attributes(status: "untracked", tracked: false)
    expect(CareLines::Evaluate.sources_of(practices("hypertension_c5").find { |p| p["key"] == "c5_d" })).to eq([])
    # Pedida assim mesmo, sem o interruptor a visita não entra em fonte nenhuma (A-12).
    visit!(days_ago: 50, measurements: { "systolic" => 120, "diastolic" => 80, "weight_kg" => 70.5, "height_cm" => 170.0 })
    expect(events(home_visits: false).values.flatten).to be_empty
    expect(c5_d(home_visits: true)).to have_attributes(tracked: true, count: 2)
  end

  it "com home_visits conta só a realizada, residencial, com motivo, por 515105 ou 322255, não retirada" do
    tacs = field_agent!(cbo: "322255")
    ace = field_agent!(cbo: "515140")
    visit!(days_ago: 10)
    visit!(agent: tacs, days_ago: 11, property_type: "7")
    visit!(agent: ace, days_ago: 12)
    visit!(days_ago: 13, has_reason: false)
    home_visit!(day: home_visit_day!(agent: acs, day: today - 14), property_type: "2", has_reason: true) # imóvel não residencial, sem pessoa
    visit!(days_ago: 15).update!(withdrawn_at: Time.current, withdrawn_by_user: acs, withdrawal_reason: "Registrada na pessoa errada")
    visit!(days_ago: 400)

    list = events.fetch("acs_visit")
    expect(list.map(&:on)).to eq([ today - 11, today - 10 ])
    expect(list.map(&:cbo)).to eq(%w[322255 515105])
    expect(list.map(&:codes)).to eq([ [], [] ])
  end

  it "visita de ACE com pressão conta em blood_pressure e não em acs_visit" do
    ace = field_agent!(cbo: "515140")
    visit!(agent: ace, days_ago: 5, measurements: { "systolic" => 130, "diastolic" => 85 })
    visit!(agent: ace, days_ago: 6, measurements: { "weight_kg" => 70.5, "height_cm" => 170.0 })
    visit!(agent: ace, days_ago: 7, measurements: { "systolic" => 130, "weight_kg" => 70.5 }) # sem par: não conta
    by_source = events
    expect(by_source.fetch("blood_pressure").map(&:on)).to eq([ today - 5 ])
    expect(by_source.fetch("weight_height").map(&:on)).to eq([ today - 6 ])
    expect(by_source.fetch("acs_visit", [])).to be_empty
    # Só a fonte pedida: a medida da visita não aparece sem blood_pressure na lista.
    expect(events(%w[acs_visit weight_height]).keys).not_to include("blood_pressure")
  end

  it "recusa e ausência não contam" do
    visit!(days_ago: 5, outcome: 2, has_reason: false)
    visit!(days_ago: 6, outcome: 3, has_reason: false)
    expect(events.values.flatten).to be_empty
  end

  it "retirada some na hora (decisão 23)" do
    visit = visit!(days_ago: 5, measurements: { "systolic" => 120, "diastolic" => 80 })
    expect(events.transform_values(&:size)).to eq("acs_visit" => 1, "blood_pressure" => 1)
    visit.update!(withdrawn_at: Time.current, withdrawn_by_user: acs, withdrawal_reason: "Registrada na pessoa errada")
    expect(events.values.flatten).to be_empty
  end

  it "uma consulta SQL para mil pacientes (contagem de queries)" do
    visit!(days_ago: 5, measurements: { "systolic" => 120, "diastolic" => 80 })
    ids = [ patient.id ] + Array.new(999) { SecureRandom.uuid }
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:cached] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { load(%w[acs_visit], ids: ids) }
    expect(queries.size).to eq(1)
    expect(queries.first).to include("home_visit_days").and(include("home_visits"))
    expect(queries.first).not_to match(/reasons|note/)

    queries.clear
    result = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { load(ids: ids) }
    expect(queries.grep(/home_visits/).size).to eq(1)
    expect(queries.grep(/home_visits/).first).not_to match(/reasons|note/)
    expect(result.fetch(patient.id).transform_values(&:size)).to eq("acs_visit" => 1, "blood_pressure" => 1)
  end

  it "min_gap_days 30: visitas a 10 e 45 dias contam 2, a 10 e 20 contam 1" do
    near = registry_patient!
    visit!(days_ago: 10)
    visit!(days_ago: 45)
    visit!(days_ago: 10, who: near)
    visit!(days_ago: 20, who: near)
    expect(c5_d(home_visits: true)).to have_attributes(tracked: true, count: 2, met: true)
    expect(c5_d(who: near, home_visits: true)).to have_attributes(tracked: true, count: 1, met: false)
  end
end
