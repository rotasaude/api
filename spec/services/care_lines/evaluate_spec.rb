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
    events = { "consultation" => [ ev("2026-09-20", cbo: "223505", codes: [ %w[ciap2 W78] ]) ], "blood_pressure" => [ ev("2026-09-20") ],
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
               "consultation" => [ ev("2026-03-01", cbo: "223505", codes: [ %w[ciap2 W14] ]), ev("2026-09-01", cbo: "225125", codes: [ %w[ciap2 R05] ]) ] }
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
    event = ev("2026-01-01", cbo: "225125", codes: [ %w[ciap2 W78] ])
    expect([ event.inspect, event.to_s ].join).not_to match(/W78|225125/)
  end

  it "pretty_print (pp) de Person e Event também não mostra dado pessoal nem código" do
    p = person(patient_id: "p1", citizen_id: "c1", birth_date: Date.new(1990, 1, 1), sex: "female", gender_identity: "trans_woman",
               problems: [ %w[ciap2 T90] ], resolved_problems: [ %w[cid10 O80] ], declared: %w[diabetes])
    out = [ PP.pp(p, +""), PP.pp(ev("2026-01-01", cbo: "225125", codes: [ %w[ciap2 W78] ]), +"") ].join
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
      expect(c3_i("consultation" => [ ev(in_window, cbo: "225125", codes: [ %w[ciap2 W90] ]) ])).to have_attributes(met: true, status: "ok")
      expect(c3_i("consultation" => [ ev(in_window, cbo: "223505", codes: [ %w[cid10 Z39] ]) ])).to have_attributes(met: true, status: "ok")
    end

    it "NÃO cumpre com consulta sem código de puerpério" do
      expect(c3_i("consultation" => [ ev(in_window, cbo: "225125", codes: [ %w[ciap2 A98] ]) ])).to have_attributes(met: false, count: 0)
      expect(c3_i("consultation" => [ ev(in_window, cbo: "225125", codes: []) ])).to have_attributes(met: false, count: 0)
    end

    it "NÃO cumpre com consulta de CBO fora de MD_NURSE, mesmo com código de puerpério" do
      expect(c3_i("consultation" => [ ev(in_window, cbo: "322205", codes: [ %w[ciap2 W90] ]) ])).to have_attributes(met: false, count: 0)
      expect(c3_i("consultation" => [ ev(in_window, cbo: nil, codes: [ %w[ciap2 W90] ]) ])).to have_attributes(met: false, count: 0)
    end
  end

  it "to_json de Person e Event não traz dado pessoal nem código (ActiveSupport faria Data#as_json = to_h)" do
    p = person(patient_id: "p1", citizen_id: "c1", birth_date: Date.new(1990, 1, 1), sex: "female", gender_identity: "trans_woman",
               problems: [ %w[ciap2 T90] ], resolved_problems: [ %w[cid10 O80] ], declared: %w[diabetes], team_id: 7)
    expect(JSON.parse(p.to_json)).to eq("patient_id" => "p1", "citizen_id" => "c1")
    expect([ p.to_json, [ p ].to_json, { person: p }.to_json ].join).not_to match(/1990|female|T90|trans_woman|O80|diabetes|birth|sex|problems|declared/)
    event = ev("2026-01-01", cbo: "225125", codes: [ %w[ciap2 W78] ])
    expect(JSON.parse(event.to_json)).to eq("on" => "2026-01-01", "cbo" => "225125")
    expect(event.to_json).not_to match(/W78|ciap2|codes/)
  end

  context "terminologia do código (a mesma lista de CIAP/CID, nunca a outra)" do
    def c7_c(codes)
      woman = person(birth_date: Date.new(1996, 2, 2), sex: "female")
      by_key(described_class.call(practices: practices("women_c7"), person: woman, anchors: { "birth" => woman.birth_date },
                                  events: { "consultation" => [ ev("2026-09-01", cbo: "225125", codes: codes) ] }, today: today))["c7_c"]
    end

    it "c7_c: CIAP N95 (cefaleia) NÃO cumpre; CID N95 (menopausa) cumpre" do
      expect(c7_c([ %w[ciap2 N95] ])).to have_attributes(met: false, count: 0)
      expect(c7_c([ %w[cid10 N95] ])).to have_attributes(met: true, status: "ok")
    end

    it "c3_i: CIAP W18 (puerpério) cumpre; CID W18 (queda) NÃO cumpre" do
      lmp = Date.new(2026, 8, 13)
      run = lambda do |codes|
        by_key(described_class.call(practices: practices("pregnancy_c3"), person: person(birth_date: Date.new(1999, 1, 2), sex: "female"),
                                    anchors: { "lmp" => lmp },
                                    events: { "consultation" => [ ev("2027-02-01", cbo: "225125", codes: codes) ] },
                                    today: Date.new(2027, 3, 1)))["c3_i"]
      end
      expect(run.call([ %w[ciap2 W18] ])).to have_attributes(met: true, status: "ok")
      expect(run.call([ %w[cid10 W18] ])).to have_attributes(met: false, count: 0)
    end
  end

  # Bordas de dia, com regras sintéticas mínimas (hoje = 22/10/2026).
  context "bordas de dia" do
    def syn(**overrides)
      raw = { "key" => "x", "label" => "x", "source" => "blood_pressure", "anchor" => "rolling", "window_days" => 10, "min_count" => 1,
              "schedule" => "end_of_window", "points" => 100 }.merge(overrides.stringify_keys)
      CareLines::Rules.practices([ raw ]).payload[:practices]
    end

    def run(list, events: {}, anchors: {}, on: today, who: person)
      described_class.call(practices: list, person: who, anchors: anchors, events: events, today: on).first
    end

    def bp(*days) = { "blood_pressure" => days.map { |d| ev(d.is_a?(Date) ? d.iso8601 : d) } }

    describe "janela móvel" do
      it "o 1º dia da janela (hoje - (janela - 1)) conta; o dia anterior não" do
        expect(run(syn, events: bp(today - 9))).to have_attributes(met: true, done_at: today - 9, due_on: today + 1)
        expect(run(syn, events: bp(today - 10))).to have_attributes(met: false, status: "overdue", count: 0, due_on: nil)
      end

      it "o evento de hoje conta; o de amanhã não" do
        expect(run(syn, events: bp(today))).to have_attributes(met: true)
        expect(run(syn, events: bp(today + 1))).to have_attributes(met: false)
      end

      it "due_soon com 30 dias para vencer; ok com 31" do
        list = syn(window_days: 40)
        expect(run(list, events: bp(today - 10))).to have_attributes(status: "due_soon", due_on: today + 30)
        expect(run(list, events: bp(today - 9))).to have_attributes(status: "ok", due_on: today + 31)
      end
    end

    describe "janela fixa, end_of_window" do
      let(:anchor) { today - 100 }
      let(:list) { syn(anchor: "enrollment", window_days: 100) } # finish = hoje

      it "hoje == fim, não feita: ainda due_soon (nunca overdue), due_on = fim" do
        expect(run(list, anchors: { "enrollment" => anchor })).to have_attributes(status: "due_soon", due_on: today, met: false, count: 0)
      end

      it "depois do fim, não feita: overdue com due_on = fim; feita no último dia vale, no dia seguinte não" do
        late = today + 1
        expect(run(list, anchors: { "enrollment" => anchor }, on: late)).to have_attributes(status: "overdue", due_on: today, met: false)
        expect(run(list, anchors: { "enrollment" => anchor }, events: bp(today), on: late)).to have_attributes(status: "ok", met: true)
        expect(run(list, anchors: { "enrollment" => anchor }, events: bp(late), on: late)).to have_attributes(status: "overdue", met: false)
      end

      it "due_soon a 30 dias do fim; ok a 31" do
        expect(run(list, anchors: { "enrollment" => anchor }, on: today - 30)).to have_attributes(status: "due_soon", due_on: today)
        expect(run(list, anchors: { "enrollment" => anchor }, on: today - 31)).to have_attributes(status: "ok", due_on: today)
      end

      it "o 1º dia da janela (âncora + início) conta; o dia anterior não" do
        started = syn(anchor: "enrollment", window_days: 100, window_start_days: 10)
        expect(run(started, anchors: { "enrollment" => anchor }, events: bp(anchor + 10))).to have_attributes(met: true)
        expect(run(started, anchors: { "enrollment" => anchor }, events: bp(anchor + 9))).to have_attributes(met: false)
      end
    end

    describe "janela fixa, proportional" do
      let(:anchor) { today - 71 }
      let(:list) { syn(anchor: "enrollment", window_days: 400, min_count: 4, schedule: "proportional") }

      it "marco = início + floor(feitas × duração / mínimo) + 1: due_soon a 30 dias do marco; ok a 31; overdue no marco" do
        events = bp(anchor + 5) # 1 feita: marco = âncora + 101
        expect(run(list, anchors: { "enrollment" => anchor }, events: events)).to have_attributes(status: "due_soon", due_on: anchor + 101, count: 1)
        expect(run(list, anchors: { "enrollment" => anchor }, events: events, on: today - 1)).to have_attributes(status: "ok", due_on: anchor + 101)
        expect(run(list, anchors: { "enrollment" => anchor }, events: events, on: anchor + 100)).to have_attributes(status: "due_soon")
        expect(run(list, anchors: { "enrollment" => anchor }, events: events, on: anchor + 101)).to have_attributes(status: "overdue", due_on: anchor + 101)
      end

      it "depois do fim sem completar: overdue com due_on = fim; no último dia o marco já passou (overdue)" do
        finish = anchor + 400
        events = bp(anchor + 5)
        expect(run(list, anchors: { "enrollment" => anchor }, events: events, on: finish + 1)).to have_attributes(status: "overdue", due_on: finish)
        expect(run(list, anchors: { "enrollment" => anchor }, events: events, on: finish)).to have_attributes(status: "overdue", due_on: anchor + 101)
      end

      it "completa no fim: ok; o evento do dia seguinte ao fim não conta" do
        finish = anchor + 400
        four = bp(anchor + 5, anchor + 100, anchor + 200, finish)
        expect(run(list, anchors: { "enrollment" => anchor }, events: four, on: finish)).to have_attributes(status: "ok", met: true, count: 4)
        late = bp(anchor + 5, anchor + 100, anchor + 200, finish + 1)
        expect(run(list, anchors: { "enrollment" => anchor }, events: late, on: finish + 1)).to have_attributes(status: "overdue", count: 3, met: false)
      end
    end

    describe "faixa de idade (applies_to 25–64)" do
      let(:list) { syn(applies_to: { "age_min_years" => 25, "age_max_years" => 64 }) }

      def applies?(birth) = described_class.call(practices: list, person: person(birth_date: birth), anchors: {}, events: {}, today: today).any?

      it "64 anos aplica; 65 não (vira 65 hoje); 25 aplica; 24 não (faz 25 amanhã)" do
        expect(applies?(Date.new(1961, 10, 23))).to be(true)  # 64 anos e 364 dias
        expect(applies?(Date.new(1961, 10, 22))).to be(false) # faz 65 hoje
        expect(applies?(Date.new(2001, 10, 22))).to be(true)  # faz 25 hoje
        expect(applies?(Date.new(2001, 10, 23))).to be(false) # faz 25 amanhã
      end

      it "sem nascimento a prática com faixa de idade não aplica" do
        expect(described_class.call(practices: list, person: person, anchors: {}, events: {}, today: today)).to be_empty
      end
    end
  end
end
