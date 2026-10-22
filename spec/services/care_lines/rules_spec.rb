require "rails_helper"

RSpec.describe CareLines::Rules do
  let(:consult) do
    { "key" => "c4_a", "label" => "Consulta em 6 meses", "source" => "consultation", "anchor" => "rolling",
      "window_days" => 183, "min_count" => 1, "schedule" => "end_of_window", "cbo_filter" => %w[2251 2235], "points" => 20 }
  end

  it "aceita prática mínima e normaliza os opcionais" do
    result = described_class.practices([ consult ])
    expect(result).to be_ok
    expect(result.payload[:practices].first).to include("window_start_days" => 0, "code_filter" => nil, "applies_to" => nil,
                                                        "all_of" => nil, "citizen_label" => nil)
  end

  it "aceita all_of, code_filter, applies_to e window_start_days" do
    tests = consult.merge("key" => "c3_g", "source" => "exam:0202031098", "anchor" => "lmp", "window_days" => 97, "cbo_filter" => nil,
                          "all_of" => [ [ { "source" => "procedure:0214010074" }, { "source" => "exam:0202031098" } ],
                                        [ { "source" => "exam:0202100251", "window_days" => 1826 } ] ])
    sexual = consult.merge("key" => "c7_c", "code_filter" => { "ciap2" => %w[W10], "cid10" => %w[Z30] },
                           "applies_to" => { "age_min_years" => 14, "age_max_years" => 69 })
    late = consult.merge("key" => "c3_f", "source" => "vaccine:57", "anchor" => "lmp", "window_start_days" => 140, "window_days" => 294,
                         "cbo_filter" => nil)
    expect(described_class.practices([ tests, sexual, late ])).to be_ok
  end

  it "aceita consulta como alternativa dentro de all_of (puerpério: consulta com código OU procedimento)" do
    puerperal = consult.merge("key" => "c3_i", "anchor" => "lmp",
                              "all_of" => [ [ { "source" => "consultation" }, { "source" => "procedure:0301010129" } ] ])
    result = described_class.practices([ puerperal ])
    expect(result).to be_ok
    expect(result.payload[:practices].first["all_of"]).to eq([ [ { "source" => "consultation" }, { "source" => "procedure:0301010129" } ] ])
  end

  it "aceita proportional com all_of de um grupo só" do
    one = consult.merge("anchor" => "lmp", "schedule" => "proportional", "min_count" => 2,
                        "all_of" => [ [ { "source" => "exam:0202010503" }, { "source" => "exam:0202010473" } ] ])
    expect(described_class.practices([ one ])).to be_ok
  end

  {
    [ { "source" => "lab:123" } ] => "practices[0].source",
    [ { "window_days" => 0 } ] => "practices[0].window_days",
    [ { "min_count" => 51 } ] => "practices[0].min_count",
    [ { "schedule" => "proportional" } ] => "practices[0].schedule", # proportional exige âncora fixa
    [ { "anchor" => "lmp", "window_start_days" => 183 } ] => "practices[0].window_start_days",
    [ { "label" => "x" * 121 } ] => "practices[0].label",
    [ { "cbo_filter" => %w[22] } ] => "practices[0].cbo_filter",
    [ { "source" => "blood_pressure", "cbo_filter" => %w[2251] } ] => "practices[0].cbo_filter",
    [ { "code_filter" => { "icd" => %w[E11] } } ] => "practices[0].code_filter",
    [ { "applies_to" => { "sex" => "x" } } ] => "practices[0].applies_to",
    [ { "all_of" => [ [ { "source" => "acs_visit" } ] ] } ] => "practices[0].all_of",
    [ { "all_of" => [ [ { "source" => "exam:0202010503" } ], [ { "source" => "exam:0202010473" } ] ], "min_count" => 2 } ] => "practices[0].min_count",
    # proportional avalia um grupo só: com vários grupos o 2º seria ignorado em silêncio
    [ { "anchor" => "lmp", "schedule" => "proportional", "min_count" => 1,
        "all_of" => [ [ { "source" => "exam:0202010503" } ], [ { "source" => "exam:0202010473" } ] ] } ] => "practices[0].schedule"
  }.each do |overrides, field|
    it "recusa #{field} (#{overrides.first.keys.join(',')})" do
      result = described_class.practices([ consult.merge(overrides.first) ])
      expect(result.reason).to eq(:invalid_practices)
      expect(result.details[:field]).to eq(field)
    end
  end

  it "recusa chave repetida, lista vazia, mais de 20 e (template) pontos que não somam 100" do
    expect(described_class.practices([ consult, consult ]).details[:field]).to eq("practices[1].key")
    expect(described_class.practices([]).details[:field]).to eq("practices")
    many = (1..21).map { |i| consult.merge("key" => "p#{i}") }
    expect(described_class.practices(many).details[:field]).to eq("practices")
    expect(described_class.practices([ consult ], template: true).details[:field]).to eq("practices.points")
  end

  it "elegibilidade: aceita as formas do catálogo e recusa vazia ou desconhecida" do
    expect(described_class.eligibility({ "problems" => { "ciap2" => %w[T90], "cid10" => %w[E11] }, "declared" => %w[diabetes] })).to be_ok
    expect(described_class.eligibility({ "age_min_years" => 9, "age_max_years" => 69, "sex" => "female",
                                         "gender_identities_included" => %w[trans_man], "gender_identities_excluded" => %w[trans_woman] })).to be_ok
    expect(described_class.eligibility({}).details[:field]).to eq("eligibility")
    expect(described_class.eligibility({ "problems" => { "ciap2" => %w[t90] } }).details[:field]).to eq("eligibility.problems")
    expect(described_class.eligibility({ "declared" => %w[none] }).details[:field]).to eq("eligibility.declared")
    expect(described_class.eligibility({ "age_min_years" => 70, "age_max_years" => 60 }).details[:field]).to eq("eligibility.age_max_years")
    expect(described_class.eligibility({ "smoker" => true }).details[:field]).to eq("eligibility.smoker")
  end

  it "lista vazia vale como ausente (ida e volta do maintenance; linha própria do dashboard)" do
    empty = described_class.eligibility({ "problems" => { "ciap2" => [], "cid10" => [] }, "age_max_days" => 730,
                                          "requires_anchor" => nil, "declared" => [] })
    expect(empty.payload[:eligibility]).to eq("age_max_days" => 730)
    mixed = described_class.eligibility({ "problems" => { "ciap2" => %w[P76], "cid10" => [] }, "declared" => %w[mental_health] })
    expect(mixed.payload[:eligibility]).to eq("problems" => { "ciap2" => %w[P76] }, "declared" => %w[mental_health])
    expect(described_class.eligibility({ "problems" => { "ciap2" => [], "cid10" => [] } }).details[:field]).to eq("eligibility")
    expect(described_class.eligibility({ "problems" => { "ciap2" => %w[t90], "cid10" => [] } }).details[:field]).to eq("eligibility.problems")
  end
end
