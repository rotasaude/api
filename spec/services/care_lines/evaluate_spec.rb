require "rails_helper"

RSpec.describe CareLines::Evaluate do
  let(:today) { Date.new(2026, 10, 22) }
  let(:entries) { CareLines::Templates::Load.entries.index_by { |e| e["key"] } }

  def practices(key) = CareLines::Rules.practices(entries.fetch(key)["practices"], template: true).payload[:practices]
  def ev(on, cbo: nil, codes: []) = CareLines::Event.new(on: Date.iso8601(on), cbo: cbo, codes: codes)
  def by_key(list) = list.index_by(&:key)
  def person(**attrs) = CareLines::Person.new(**attrs)

  it "C4 (janela móvel): consulta em dia, PA vencendo, HbA1c fora da janela, pés em dia; técnico não conta; ACS não rastreado" do
    events = {
      "consultation" => [ ev("2026-06-01", cbo: "225125"), ev("2026-10-01", cbo: "322205") ],
      "blood_pressure" => [ ev("2026-05-10") ], "weight_height" => [ ev("2026-06-01") ],
      "exam:0202010503" => [ ev("2025-09-01") ], "procedure:0301040095" => [ ev("2026-01-15") ]
    }
    result = by_key(described_class.call(practices: practices("diabetes_c4"), person: person(birth_date: Date.new(1968, 3, 1), sex: "male"),
                                         anchors: { "enrollment" => today }, events: events, today: today))
    expect(result["c4_a"]).to have_attributes(status: "ok", done_at: Date.new(2026, 6, 1), due_on: Date.new(2026, 12, 1), count: 1, met: true)
    expect(result["c4_b"]).to have_attributes(status: "due_soon", due_on: Date.new(2026, 11, 9), met: true)
    expect(result["c4_c"]).to have_attributes(status: "ok", due_on: Date.new(2027, 6, 1))
    expect(result["c4_d"]).to have_attributes(status: "untracked", tracked: false, met: false, due_on: nil)
    expect(result["c4_e"]).to have_attributes(status: "overdue", done_at: nil, due_on: nil, count: 0, met: false)
    expect(result["c4_f"]).to have_attributes(status: "ok", due_on: Date.new(2027, 1, 15))
    expect(described_class.worst(result.values)).to eq("overdue")
  end

  it "C2 (nascimento, proporcional): 1ª consulta até 30 dias; 2 de 9 aos 150 dias em dia; 1 peso+altura atrasado" do
    birth = Date.new(2026, 5, 25)
    events = { "consultation" => [ ev("2026-06-10", cbo: "223505"), ev("2026-08-01", cbo: "225125") ],
               "weight_height" => [ ev("2026-06-10") ] }
    result = by_key(described_class.call(practices: practices("child_c2"), person: person(birth_date: birth, sex: "male"),
                                         anchors: { "birth" => birth, "enrollment" => today }, events: events, today: today))
    expect(result["c2_a"]).to have_attributes(status: "ok", done_at: Date.new(2026, 6, 10), due_on: nil, met: true)
    expect(result["c2_b"]).to have_attributes(status: "due_soon", count: 2, expected: 2, due_on: Date.new(2026, 11, 4), met: true)
    expect(result["c2_c"]).to have_attributes(status: "overdue", count: 1, expected: 2, due_on: Date.new(2026, 8, 15), met: false)
    expect(result.values_at("c2_d", "c2_e").map(&:status)).to eq(%w[untracked untracked])
  end

  it "C3 (DUM): 1ª consulta ok; 7 consultas atrasadas; 1º trimestre com 2 de 4 grupos vencendo; 3º trimestre ainda não começou" do
    lmp = Date.new(2026, 8, 13)
    events = { "consultation" => [ ev("2026-09-20", cbo: "223505", codes: %w[W78]) ], "blood_pressure" => [ ev("2026-09-20") ],
               "weight_height" => [ ev("2026-09-20") ], "procedure:0214010074" => [ ev("2026-09-20") ],
               "exam:0202030300" => [ ev("2026-09-20") ] }
    result = by_key(described_class.call(practices: practices("pregnancy_c3"), person: person(birth_date: Date.new(1999, 1, 2), sex: "female"),
                                         anchors: { "lmp" => lmp, "enrollment" => today }, events: events, today: today))
    expect(result["c3_a"]).to have_attributes(status: "ok", met: true)
    expect(result["c3_b"]).to have_attributes(status: "overdue", count: 1, expected: 2, due_on: Date.new(2026, 9, 25), met: false)
    expect(result["c3_g"]).to have_attributes(status: "due_soon", count: 2, expected: 4, due_on: Date.new(2026, 11, 18), met: false)
    expect(result["c3_h"]).to have_attributes(status: "ok", count: 0, due_on: Date.new(2027, 6, 3), met: false)
    expect(result["c3_i"]).to have_attributes(status: "ok", due_on: Date.new(2027, 7, 15))
    expect(result.values_at("c3_e", "c3_f", "c3_j", "c3_k").map(&:tracked)).to eq([ false, false, false, false ])
  end

  it "C7: só as práticas da faixa; HPV molecular vale 60 meses; saúde sexual exige o código" do
    events = { "exam:0202100251" => [ ev("2023-01-10") ], "exam:0203010086" => [ ev("2022-05-01") ],
               "consultation" => [ ev("2026-03-01", cbo: "223505", codes: %w[W14]), ev("2026-09-01", cbo: "225125", codes: %w[R05]) ] }
    woman = person(birth_date: Date.new(1996, 2, 2), sex: "female")
    result = by_key(described_class.call(practices: practices("women_c7"), person: woman, anchors: { "birth" => woman.birth_date },
                                         events: events, today: today))
    expect(result.keys).to eq(%w[c7_a c7_c])
    expect(result["c7_a"]).to have_attributes(status: "ok", done_at: Date.new(2023, 1, 10), due_on: Date.new(2028, 1, 10), met: true)
    expect(result["c7_c"]).to have_attributes(status: "ok", done_at: Date.new(2026, 3, 1), due_on: Date.new(2027, 3, 1))
  end

  it "não rastreado nunca piora; sem nada rastreado a pessoa fica untracked" do
    only_untracked = practices("elderly_c6").select { |p| CareLines::Catalog.untracked?(p["source"]) }
    result = described_class.call(practices: only_untracked, person: person(birth_date: Date.new(1950, 1, 1)), anchors: {}, events: {}, today: today)
    expect(described_class.worst(result)).to eq("untracked")
    mixed = practices("elderly_c6")
    result = described_class.call(practices: mixed, person: person(birth_date: Date.new(1950, 1, 1)), anchors: {},
                                  events: { "consultation" => [ ev("2026-10-01", cbo: "225125") ], "weight_height" => [ ev("2026-10-01") ] },
                                  today: today)
    expect(described_class.worst(result)).to eq("ok")
  end

  it "sem âncora (gestante sem DUM): rastreadas ficam overdue sem data, nunca cumpridas" do
    result = by_key(described_class.call(practices: practices("pregnancy_c3"), person: person, anchors: {}, events: {}, today: today))
    expect(result["c3_a"]).to have_attributes(status: "overdue", due_on: nil, met: false)
  end

  it "since: início da janela mais antiga entre as rastreadas" do
    expect(described_class.since(practices("women_c7"), { "birth" => Date.new(1996, 2, 2) }, today)).to eq(today - 1825)
    expect(described_class.since(practices("pregnancy_c3"), { "lmp" => Date.new(2026, 8, 13) }, today)).to eq(Date.new(2026, 8, 13))
  end

  it "inspect de Person e Event não mostra dado pessoal nem código" do
    p = person(patient_id: "p1", birth_date: Date.new(1990, 1, 1), sex: "female", gender_identity: "trans_woman",
               problems: [ %w[ciap2 T90] ], resolved_problems: [ %w[cid10 O80] ], declared: %w[diabetes])
    expect([ p.inspect, p.to_s ].join).not_to match(/1990|female|T90|trans_woman|O80|diabetes/)
    expect(p.inspect).to include("p1")
    event = ev("2026-01-01", cbo: "225125", codes: %w[W78])
    expect([ event.inspect, event.to_s ].join).not_to match(/W78|225125/)
  end

  it "pretty_print (pp) de Person e Event também não mostra dado pessoal nem código" do
    p = person(patient_id: "p1", citizen_id: "c1", birth_date: Date.new(1990, 1, 1), sex: "female", gender_identity: "trans_woman",
               problems: [ %w[ciap2 T90] ], resolved_problems: [ %w[cid10 O80] ], declared: %w[diabetes])
    out = [ PP.pp(p, +""), PP.pp(ev("2026-01-01", cbo: "225125", codes: %w[W78]), +"") ].join
    expect(out).not_to match(/1990|female|T90|trans_woman|O80|diabetes|W78|225125/)
    expect(out).to include("p1", "c1")
  end

  # Decisão P6 (errata): na prática com all_of, a alternativa { source: consultation }
  # herda o cbo_filter e o code_filter DA PRÁTICA. Regras lidas do catálogo-base real.
  context "c3_i (consulta de puerpério OU procedimento 0301010129)" do
    let(:lmp) { Date.new(2026, 8, 13) } # janela: DUM + 154 .. DUM + 336 = 14/01/2027 .. 15/07/2027
    let(:in_window) { "2027-02-01" }
    let(:today_in_window) { Date.new(2027, 3, 1) }

    def c3_i(events)
      by_key(described_class.call(practices: practices("pregnancy_c3"), person: person(birth_date: Date.new(1999, 1, 2), sex: "female"),
                                  anchors: { "lmp" => lmp }, events: events, today: today_in_window))["c3_i"]
    end

    it "usa os filtros do YAML real na prática" do
      practice = practices("pregnancy_c3").find { |x| x["key"] == "c3_i" }
      expect(practice["all_of"]).to eq([ [ { "source" => "consultation" }, { "source" => "procedure:0301010129" } ] ])
      expect(practice["cbo_filter"]).to eq(%w[2231 2251 2252 2253 2235])
      expect(practice["code_filter"].values.flatten).to include("W90", "Z39")
    end

    it "cumpre com o procedimento" do
      expect(c3_i("procedure:0301010129" => [ ev(in_window) ])).to have_attributes(met: true, status: "ok", done_at: Date.iso8601(in_window))
    end

    it "cumpre com consulta de médico ou enfermeiro com código de puerpério" do
      expect(c3_i("consultation" => [ ev(in_window, cbo: "225125", codes: %w[W90]) ])).to have_attributes(met: true, status: "ok")
      expect(c3_i("consultation" => [ ev(in_window, cbo: "223505", codes: %w[Z39]) ])).to have_attributes(met: true, status: "ok")
    end

    it "NÃO cumpre com consulta sem código de puerpério" do
      expect(c3_i("consultation" => [ ev(in_window, cbo: "225125", codes: %w[A98]) ])).to have_attributes(met: false, count: 0)
      expect(c3_i("consultation" => [ ev(in_window, cbo: "225125", codes: []) ])).to have_attributes(met: false, count: 0)
    end

    it "NÃO cumpre com consulta de CBO fora de MD_NURSE, mesmo com código de puerpério" do
      expect(c3_i("consultation" => [ ev(in_window, cbo: "322205", codes: %w[W90]) ])).to have_attributes(met: false, count: 0)
      expect(c3_i("consultation" => [ ev(in_window, cbo: nil, codes: %w[W90]) ])).to have_attributes(met: false, count: 0)
    end
  end
end
