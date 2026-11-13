require "rails_helper"

# Módulo 24b, Task 17 (ADR 0052; contrato §12, Q18, Q22, Q23): a visita
# domiciliar na linha do tempo. Profissional: todos os desfechos e a retirada,
# título "Visita domiciliar", resumo com desfecho, rótulos dos motivos e das
# medidas, dono da folha, status recorded | withdrawn e detail_ref
# { type: "home_visit", id }; nunca a observação. Cidadão (`citizen: true`): só
# a realizada (outcome 1) não retirada, na forma fixa da Q22, com occurred_at =
# meio-dia local do dia da folha — na ordem, na janela e no cursor. Pessoa da
# entrada = patient_id (o responsável, na visita à família). Não consulta o
# interruptor (registro retido).
RSpec.describe Timeline::Sources::HomeVisitSource do
  let!(:city) { home_visit_city! }
  let(:team) { registry_team! }
  let(:agent) { field_agent!(team: team) }
  let(:patient) { registry_patient! }
  let(:person) { Timeline::Person.for_patient(patient) }
  let(:note) { "MARCADOR-OBSERVACAO da visita" }

  def entries(**opts) = described_class.entries(person: person, before: nil, limit: 10, from: nil, to: nil, **opts)
  def day!(on) = home_visit_day!(agent: agent, team: team, day: on)
  def noon(on) = Time.zone.parse("#{on.iso8601} 12:00")

  def visit!(day:, at: nil, **over)
    home_visit!(day: day, occurred_at: at, subject: "resident", patient: patient, **over)
  end

  def done!(day:, at: nil, **over)
    visit!(day: day, at: at, outcome: 1, has_reason: true, reasons: [ 29, 5 ], **over)
  end

  def withdraw!(visit)
    visit.update!(withdrawn_at: Time.current, withdrawn_by_user: agent, withdrawal_reason: "Registrei no morador errado")
    visit
  end

  it "profissional vê recusa, ausência e retirada com motivos e medidas, nunca a observação" do
    on = Date.current - 1
    sheet = day!(on)
    done = done!(day: sheet, at: on.in_time_zone.change(hour: 15), note: note,
                 measurements: { "weight_kg" => 70.5, "height_cm" => 170, "systolic" => 120, "diastolic" => 80 })
    refused = visit!(day: sheet, at: on.in_time_zone.change(hour: 11), outcome: 2, note: note)
    absent = visit!(day: sheet, at: on.in_time_zone.change(hour: 10), outcome: 3)
    withdrawn = withdraw!(done!(day: sheet, at: on.in_time_zone.change(hour: 9)))

    rows = entries
    expect(rows.map(&:source_id)).to eq([ done.id, refused.id, absent.id, withdrawn.id ])
    expect(rows.first).to have_attributes(
      kind: "home_visit", occurred_at: done.occurred_at, title: "Visita domiciliar",
      summary: "Visita realizada · Visita periódica, Gestante · peso, altura, pressão arterial",
      professional: { name: agent.professional.professional_name, cbo_code: sheet.cbo },
      unit: { id: team.health_unit.id, name: team.health_unit.name },
      status: "recorded", detail_ref: { type: "home_visit", id: done.id }, document: nil, citizen: nil
    )
    expect(rows.map(&:summary)).to eq([ "Visita realizada · Visita periódica, Gestante · peso, altura, pressão arterial",
                                        "Visita recusada", "Ausente", "Visita realizada · Visita periódica, Gestante" ])
    expect(rows.map(&:status)).to eq(%w[recorded recorded recorded withdrawn])
    json = rows.map { |entry| Timeline::Json.professional(entry) }.to_json
    expect(json).not_to include(note, "MARCADOR", "Registrei no morador errado")
    # Fail-closed: a forma do profissional não monta a visão do cidadão.
    expect(rows.map { |entry| Timeline::Json.citizen(entry) }).to all(be_nil)
  end

  it "cidadão vê só a realizada, sem nome, unidade, resumo nem status" do
    on = Date.current - 2
    sheet = day!(on)
    done = done!(day: sheet, at: on.in_time_zone.change(hour: 16, min: 47), note: note, measurements: { "temperature_c" => 37.2 })
    visit!(day: sheet, outcome: 2)
    visit!(day: sheet, outcome: 3)
    withdraw!(done!(day: sheet))

    entry = entries(citizen: true).sole

    expect(entry).to have_attributes(kind: "home_visit", source_id: done.id, occurred_at: noon(on), unit: nil, professional: nil,
                                     summary: nil, status: nil, detail_ref: nil, document: nil)
    expect(entry.occurred_at.in_time_zone.strftime("%Y-%m-%d %H:%M")).to eq("#{on.iso8601} 12:00")
    expect(Timeline::Json.citizen(entry)).to eq(id: "home_visit:#{done.id}", kind: "home_visit", occurred_at: noon(on).iso8601, unit: nil,
                                                professional_name: nil, title: "Visita do agente de saúde", summary: nil, status: nil,
                                                document: nil)
    expect(Timeline::Json.citizen(entry).to_json).not_to include(note, "Gestante", "16:47", agent.professional.professional_name)
  end

  it "cidadão: ordem, janela e cursor pelo meio-dia local do dia da folha (Q22)" do
    d1 = Date.current - 1
    d2 = Date.current - 2
    d3 = Date.current - 3
    late = done!(day: day!(d1), at: d1.in_time_zone.change(hour: 7))
    same = day!(d2)
    morning = done!(day: same, at: d2.in_time_zone.change(hour: 8))
    evening = done!(day: same, at: d2.in_time_zone.change(hour: 19))
    oldest = done!(day: day!(d3), at: d3.in_time_zone.change(hour: 23))
    pair = [ morning, evening ].sort_by(&:id)

    expect(entries(citizen: true).map(&:source_id)).to eq([ late.id, *pair.map(&:id), oldest.id ])
    expect(entries(citizen: true).map(&:occurred_at)).to eq([ noon(d1), noon(d2), noon(d2), noon(d3) ])

    # Teto fixo de páginas: uma regressão do cursor falha aqui em vez de girar sem fim na fila do bin/test.
    seen = []
    before = nil
    6.times do
      page = Timeline::Query.call(person: person, kinds: %w[home_visit], limit: 1, before: before, citizen_view: true)
      seen.concat(page.entries.map(&:source_id))
      before = page.next_before && Timeline::Cursor.decode(page.next_before)
      break unless before
    end
    expect(before).to be_nil
    expect(seen).to eq([ late.id, *pair.map(&:id), oldest.id ])

    # A janela também é pelo meio-dia: 12:00–12:00 do d2 pega as duas do dia, não a das 19h fora dele.
    window = described_class.entries(person: person, before: nil, limit: 10, from: noon(d2), to: noon(d2), citizen: true)
    expect(window.map(&:source_id)).to match_array(pair.map(&:id))
  end

  it "visita à família aparece para o responsável e não para outro morador da mesma família (Q23)" do
    household = registry_household!
    family = registry_family!(household, responsible: patient)
    member = registry_patient!
    params = registry_registration_params(household, patient: member).merge("family_id" => family.id)
    joined = TerritoryRegistry::SaveRegistration.call(params: params, by: registry_acs_of(household))
    expect(joined).to be_ok
    expect(joined.payload[:registration]).to have_attributes(patient_id: member.id, family_id: family.id, household_id: household.id,
                                                             is_responsible: false)
    visit = done!(day: day!(Date.current), subject: "family_responsible", family: family, household: household, reasons: [ 29 ])

    expect(entries.map(&:source_id)).to eq([ visit.id ])
    expect(entries(citizen: true).map(&:source_id)).to eq([ visit.id ])
    resident = Timeline::Person.for_patient(member)
    expect(described_class.entries(person: resident, before: nil, limit: 10, from: nil, to: nil)).to eq([])
    expect(described_class.entries(person: resident, before: nil, limit: 10, from: nil, to: nil, citizen: true)).to eq([])
  end

  it "não consulta o interruptor; sem paciente, vazio" do
    visit = done!(day: day!(Date.current))
    Platform::Features.set!(city: city, key: HomeVisits::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    expect(HomeVisits::Gate.usable?(city.reload)).to be(false)
    expect(entries.map(&:source_id)).to eq([ visit.id ])
    expect(entries(citizen: true).map(&:source_id)).to eq([ visit.id ])

    nobody = Timeline::Person.new(citizen_ids: [], patient_id: nil, verified: false)
    expect(described_class.entries(person: nobody, before: nil, limit: 10, from: nil, to: nil)).to eq([])
  end
end
