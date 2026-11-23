require "rails_helper"

# Módulo 35b, Task 1 (prova técnica): a tabela de amostra da LV (manual LV-2026,
# 4.6.4.1, Tabela 4, coluna de 2%), os padrões de fábrica do §9 e os rótulos
# dos domínios. O texto do manual não é copiado; só os valores.
RSpec.describe "Prova técnica do 35b", type: :model do
  let(:defaults) { YAML.load_file(Rails.root.join("config/zoonoses/defaults.yml")) }
  let(:table) { defaults.fetch("leish_sample_table") }

  it "os padrões são os do §9 sem leish_expected_prevalence" do
    expect(defaults).to include(
      "observation_days" => 10, "collar_months" => 6, "leish_focus_min_dogs" => 100,
      "dogs_per_block" => 16, "rabies_coverage_target" => 0.8,
      "dog_population_estimate" => nil, "cat_population_estimate" => nil
    )
    expect(defaults).not_to have_key("leish_expected_prevalence")
    expect(defaults.keys).to match_array(%w[
      observation_days collar_months leish_sample_table leish_focus_min_dogs
      dogs_per_block rabies_coverage_target dog_population_estimate cat_population_estimate
    ])
  end

  it "leish_sample_table tem linhas de população estritamente crescentes e amostra ≤ população" do
    populations = table.map { |row| row.fetch("population") }
    expect(populations).to eq(populations.sort.uniq)
    expect(table).to all(satisfy { |row| row["sample"] <= row["population"] })
    expect(table.map { |row| row["sample"] }).to eq(table.map { |row| row["sample"] }.sort)
  end

  it "a linha de 600 dá 334 (pesquisa §3.5; manual 4.6.4.1)" do
    row = table.find { |r| r["population"] >= 600 }
    expect(row["sample"]).to eq(334)
  end

  it "a fonte tem URL, data, páginas e SHA-256" do
    source = YAML.load_file(Rails.root.join("config/zoonoses/sources.yml")).fetch("leish_manual")
    expect(source["url"]).to start_with("https://www.gov.br/saude/")
    expect(source["fetched_on"]).to match(/\A\d{4}-\d{2}-\d{2}\z/)
    expect(source["pages"]).to be_present
    expect(source["sha256"]).to match(/\A\h{64}\z/)
  end

  it "domains.yml traz os oito subtipos com os rótulos do §4, na ordem de Catalog::SUBTYPES" do
    subtypes = YAML.load_file(Rails.root.join("config/zoonoses/domains.yml")).fetch("subtypes")
    expect(subtypes.map { |s| s["code"] }).to eq(Zoonoses::Catalog::SUBTYPES)
    expect(subtypes.map { |s| s["label"] }).to eq([
      "Escorpião", "Morcego", "Rato ou outro roedor", "Carrapato",
      "Animal que mordeu ou atacou", "Animal com comportamento estranho ou paralisia",
      "Gato com feridas (esporotricose)", "Outro problema com animal"
    ])
  end
end
