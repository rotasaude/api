require "rails_helper"

# ADR 0033: as listas transcritas da fonte oficial (Task 5) batem com o que o
# SOURCES.yml diz ter lido, e contêm as substâncias que a APS mais encontra.
RSpec.describe "config/medications/anvisa" do
  dir = Rails.root.join("config/medications/anvisa")
  sources = YAML.load_file(dir.join("SOURCES.yml"))
  antimicrobials = CSV.read(dir.join("antimicrobials.csv"), headers: true).map { |row| row["substance"] }
  controlled = CSV.read(dir.join("controlled.csv"), headers: true).map { |row| [ row["substance"], row["list"] ] }

  it "as contagens batem com a fonte declarada e nada se repete" do
    expect(antimicrobials.size).to eq(sources.dig("antimicrobials", "count"))
    expect(controlled.group_by(&:last).transform_values(&:size)).to eq(sources.dig("controlled", "counts").transform_keys(&:to_s))
    expect(antimicrobials).to eq(antimicrobials.uniq)
    expect(controlled.map(&:first)).to eq(controlled.map(&:first).uniq)
    expect((antimicrobials + controlled.map(&:first)).all? { |name| name == name.upcase && name.strip == name }).to be(true)
    expect(controlled.map(&:last).uniq - %w[A1 A2 A3 B1 B2 C1 C2 C3 C4 C5]).to eq([])
    expect(sources.to_yaml).not_to include("<")
  end

  it "traz as substâncias de referência da APS" do
    keys = antimicrobials.map { |name| Medications::Substances.key(name) }
    expect(keys).to include("AMOXICILINA", "AZITROMICINA", "CEFALEXINA", "CIPROFLOXACINO", "NITROFURANTOINA", "SULFAMETOXAZOL")
    lists = controlled.to_h { |name, list| [ Medications::Substances.key(name), list ] }
    expect(lists).to include("DIAZEPAM" => "B1", "CLONAZEPAM" => "B1", "FENOBARBITAL" => "B1", "MORFINA" => "A1",
                             "METADONA" => "A1", "CODEINA" => "A2", "TRAMADOL" => "A2", "FLUOXETINA" => "C1",
                             "AMITRIPTILINA" => "C1", "CARBAMAZEPINA" => "C1")
  end
end
