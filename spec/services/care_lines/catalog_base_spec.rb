require "rails_helper"

RSpec.describe "Catálogo-base das linhas (notas metodológicas C2–C7 de 19/06/2026)" do
  let(:entries) { CareLines::Templates::Load.entries.index_by { |e| e["key"] } }
  let(:md_nurse) { %w[2231 2251 2252 2253 2235] }

  def practice(key, practice_key) = entries.fetch(key)["practices"].find { |p| p["key"] == practice_key }

  it "seis linhas válidas pelo Rules, pontos somando 100" do
    expect(entries.keys).to eq(CareLines::Catalog::TEMPLATE_KEYS)
    entries.each_value do |e|
      expect(CareLines::Rules.practices(e["practices"], template: true)).to be_ok
      expect(CareLines::Rules.eligibility(e["eligibility"])).to be_ok
      expect(e["indicator"]).to eq(CareLines::Catalog::INDICATORS.fetch(e["key"]))
    end
  end

  it "pontos por prática como os Quadros 01" do
    expect(entries.transform_values { |e| e["practices"].map { |p| p["points"] } }).to eq(
      "child_c2" => [ 20, 20, 20, 20, 20 ], "pregnancy_c3" => [ 10, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9 ],
      "diabetes_c4" => [ 20, 15, 15, 20, 15, 15 ], "hypertension_c5" => [ 25, 25, 25, 25 ],
      "elderly_c6" => [ 25, 25, 25, 25 ], "women_c7" => [ 20, 30, 30, 20 ]
    )
  end

  it "elegibilidade por CIAP/CID, idade e sexo" do
    expect(entries["diabetes_c4"]["eligibility"]["problems"]).to eq("ciap2" => %w[T89 T90], "cid10" => %w[E10 E11 E14])
    expect(entries["hypertension_c5"]["eligibility"]["problems"]).to eq("ciap2" => %w[K86 K87], "cid10" => %w[I10 I11 I12 I13 I15 O10 O11])
    expect(entries["pregnancy_c3"]["eligibility"]).to include("requires_anchor" => "lmp",
                                                               "exclude_problems" => { "ciap2" => %w[W82 W83], "cid10" => %w[O02 O03 O04 O05 O06 Z303] })
    expect(entries["pregnancy_c3"]["eligibility"]["problems"]["ciap2"]).to eq(%w[W03 W78 W79 W81 W84 W85])
    expect(entries["child_c2"]["eligibility"]).to eq("age_max_days" => 730)
    expect(entries["elderly_c6"]["eligibility"]).to eq("age_min_years" => 60)
    expect(entries["women_c7"]["eligibility"]).to eq("age_min_years" => 9, "age_max_years" => 69, "sex" => "female",
                                                     "gender_identities_included" => %w[trans_man],
                                                     "gender_identities_excluded" => %w[trans_woman])
  end

  it "janelas, contagens, âncoras e fontes que fazem a diferença" do
    expect(practice("child_c2", "c2_b")).to include("anchor" => "birth", "window_days" => 730, "min_count" => 9, "schedule" => "proportional",
                                                    "cbo_filter" => md_nurse)
    expect(practice("pregnancy_c3", "c3_a")).to include("anchor" => "lmp", "window_days" => 84, "min_count" => 1)
    expect(practice("pregnancy_c3", "c3_g")["all_of"].size).to eq(4)
    expect(practice("pregnancy_c3", "c3_h")).to include("window_start_days" => 196, "window_days" => 294)
    expect(practice("pregnancy_c3", "c3_k")["source"]).to eq("oral_health")
    expect(practice("diabetes_c4", "c4_e")).to include("source" => "exam:0202010503", "anchor" => "rolling", "window_days" => 365)
    expect(practice("diabetes_c4", "c4_f")).to include("source" => "procedure:0301040095", "window_days" => 365)
    expect(practice("hypertension_c5", "c5_a")).to include("source" => "consultation", "window_days" => 183, "cbo_filter" => md_nurse)
    expect(practice("women_c7", "c7_a")["all_of"].first.last).to eq("source" => "exam:0202100251", "window_days" => 1826)
    expect(practice("women_c7", "c7_c")["applies_to"]).to eq("age_min_years" => 14, "age_max_years" => 69)
    untracked = entries.values.flat_map { |e| e["practices"] }.select { |p| CareLines::Catalog.untracked?(p["source"]) }.map { |p| p["key"] }
    expect(untracked).to eq(%w[c2_d c2_e c3_e c3_f c3_j c3_k c4_d c5_d c6_c c6_d c7_b])
  end

  # Errata C-api-01 / decisão P6: consulta com código de puerpério (cbo e
  # code_filter da própria prática) OU o procedimento 0301010129.
  it "c3_i: consulta de puerpério com code_filter e cbo, ou o procedimento 0301010129" do
    c3_i = practice("pregnancy_c3", "c3_i")
    expect(c3_i).to include("source" => "consultation", "cbo_filter" => md_nurse,
                            "all_of" => [ [ { "source" => "consultation" }, { "source" => "procedure:0301010129" } ] ])
    expect(c3_i["code_filter"]["ciap2"]).to include("W18", "W90")
  end
end
