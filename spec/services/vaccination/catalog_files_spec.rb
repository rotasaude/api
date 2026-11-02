require "rails_helper"

# Módulo 29 (ADR 0047; §15 V9/V14): os YAML de config/vaccination e as classes que os leem.
RSpec.describe "YAML do módulo 29" do
  let(:c2_codes) { %w[9 17 22 24 26 29 39 42 43 46 47 56 58 59 106 107] }

  it "todo produto tem fabricante; multidose só com prazo após aberto positivo; códigos únicos" do
    products = Vaccination::Immunobiologicals.all
    expect(products.map(&:code).uniq.size).to eq(products.size)
    expect(products).to all(satisfy { |p| p.manufacturers.any? })
    expect(products.select(&:multidose)).to all(satisfy { |p| p.doses_per_vial > 1 && p.manufacturers.all? { |m| m.validity_after_opening_hours.positive? } })
    expect(products.reject(&:multidose)).to all(satisfy { |p| p.doses_per_vial == 1 && p.manufacturers.all? { |m| m.validity_after_opening_hours.zero? } })
  end

  it "rota padrão e local padrão existem nas terminologias; fabricante sem código (V9)" do
    Vaccination::Immunobiologicals.all.each do |p|
      expect(Vaccination::Terminologies.valid?("route", p.default_route)).to be(true), "rota de #{p.code}"
      expect(Vaccination::Terminologies.valid?("site", p.default_site)).to be(true), "local de #{p.code}"
    end
    expect(Vaccination::Immunobiologicals.all.flat_map(&:manufacturers).map(&:code)).to all(be_nil)
  end

  it "toda dose do calendário existe nas terminologias e todo código aceito existe no catálogo" do
    Vaccination::Calendar.current.series.each do |series|
      expect(series.accepts).to all(satisfy { |code| Vaccination::Immunobiologicals.find(code) })
      expect(series.doses.map(&:dose_code)).to all(satisfy { |code| Vaccination::Terminologies.valid?("dose", code) })
    end
  end

  it "Version#entry devolve [série, dose] ou nil" do
    series, dose = Vaccination::Calendar.current.entry("42", "2")
    expect([ series.key, dose.recommended_age_days, dose.min_interval_days ]).to eq([ "penta", 120, 30 ])
    expect(Vaccination::Calendar.current.entry("42", "9")).to be_nil
    expect(Vaccination::Calendar.current.entry("999", "1")).to be_nil
    expect([ Vaccination::Calendar.current.version, Vaccination::Calendar.current.due_window_days ]).to eq([ "2026.1", 30 ])
  end

  it "os 16 códigos do C2 estão no catálogo com o nome da nota" do
    expect(Vaccination::Immunobiologicals.find("42").name).to eq("Vacina penta (DTP/HB/Hib)")
    expect(c2_codes.map { |code| Vaccination::Immunobiologicals.find(code) }).to all(be_present)
    c2 = YAML.load_file(Rails.root.join("config/vaccination/c2_schedule.yml"))
    expect(c2["codes"].keys).to match_array(c2_codes)
  end

  it "Product#manufacturer resolve pela key; código nulo não identifica" do
    bcg = Vaccination::Immunobiologicals.find("15")
    expect(bcg.manufacturer("fiocruz").name).to eq("Fiocruz")
    expect(bcg.manufacturer(:serum).key).to eq("serum")
    expect([ bcg.manufacturer("nope"), bcg.manufacturer(nil), bcg.manufacturer("") ]).to all(be_nil)
    expect(Vaccination::Immunobiologicals.all.flat_map { |p| p.manufacturers.map(&:key) }).to all(be_present)
    expect(Vaccination::Immunobiologicals.all).to all(satisfy { |p| p.manufacturers.map(&:key).uniq.size == p.manufacturers.size })
  end

  it "código canônico é o do LEDI: find normaliza zero à esquerda; nenhum outro código do catálogo/C2 tem zero" do
    expect(Vaccination::Immunobiologicals.find("09")).to equal(Vaccination::Immunobiologicals.find("9"))
    expect(Vaccination::Immunobiologicals.find("9").name).to eq("Vacina hepatite B")
    expect(Vaccination::Immunobiologicals.find("0")).to be_nil
    expect(Vaccination::Calendar.current.entry("09", "8").first.key).to eq("hepb_birth")
    codes = Vaccination::Immunobiologicals.all.map(&:code) + YAML.load_file(Rails.root.join("config/vaccination/c2_schedule.yml"))["codes"].keys
    expect(codes).to all(match(/\A[1-9]\d*\z/))
  end

  it "grupos inativos: fora da lista, aceitos por valid?/name, recusáveis por active?" do
    inactive = Vaccination::YamlFiles.load("rnds_terminologies")["care_group"]["items"].select { |i| i["active"] == false }
    expect(inactive.size).to eq(22)
    expect(Vaccination::Terminologies.list("care_group").size).to eq(108 - 22)
    inactive.each do |item|
      expect(Vaccination::Terminologies.list("care_group").map { |i| i[:code] }).not_to include(item["code"])
      expect(Vaccination::Terminologies.valid?("care_group", item["code"])).to be(true)
      expect(Vaccination::Terminologies.name("care_group", item["code"])).to eq(item["name"])
      expect(Vaccination::Terminologies.active?("care_group", item["code"])).to be(false)
    end
    expect(Vaccination::Terminologies.active?("care_group", "121")).to be(true)
    expect(Vaccination::Terminologies.active?("care_group", "99999")).to be(false)
    expect(Vaccination::Terminologies.active?("dose", "1")).to be(true)
  end

  it "terminologias: forma { code, name }, validação, nome, estratégia pelo código RNDS" do
    expect(Vaccination::Terminologies::KINDS).to eq(%w[dose strategy route site care_group maternal_condition])
    Vaccination::Terminologies::KINDS.each { |kind| expect(Vaccination::Terminologies.list(kind)).to all(match(code: String, name: String)) }
    expect(Vaccination::Terminologies.list("strategy").map { |i| i[:code] }).to eq((1..14).map(&:to_s))
    expect(Vaccination::Terminologies.name("strategy", "1")).to eq("Rotina")
    expect(Vaccination::Terminologies.valid?("maternal_condition", "2")).to be(true)
    expect(Vaccination::Terminologies.valid?("route", "4")).to be(false)
    expect(Vaccination::Terminologies.valid?("nope", "1")).to be(false)
    expect(Vaccination::Terminologies.valid?("care_group", "121")).to be(true)
    expect(Vaccination::Terminologies.rnds_code("route", "3")).to eq("10890")
  end

  it "os cinco arquivos têm review e source; under_review? enquanto houver review true" do
    Vaccination::YamlFiles::NAMES.each { |name| expect(Vaccination::YamlFiles.load(name)["source"]).to be_present }
    expect(Vaccination::Calendar.current.series.flat_map(&:doses)).to all(satisfy { |d| d.review == true && d.source.present? })
    expect(Vaccination::Catalog.under_review?).to be(true)
  end

  it "under_review? vira false sem nenhum review true" do
    allow(Vaccination::YamlFiles).to receive(:load).and_return({ "review" => false, "items" => [ { "review" => false } ] })
    expect(Vaccination::Catalog.under_review?).to be(false)
  end
end
