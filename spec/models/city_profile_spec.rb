require "rails_helper"

# Identidade da cidade no banco dela (spec banco-por-cidade §3, Plano 4): um dump
# restaurado sozinho continua sabendo de que cidade é.
RSpec.describe CityProfile do
  it "holds at most one row per city database" do
    described_class.create!(name: "Cidade A", uf: "PR", ibge_code: "4106902")

    expect { described_class.create!(name: "Outra") }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "refuses a row that is not the singleton" do
    expect { described_class.create!(name: "Cidade A", singleton: false) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_city_profile_singleton/)
  end

  it "returns the row as .current, and nil before provisioning" do
    expect(described_class.current).to be_nil

    profile = described_class.create!(name: "Cidade A", uf: "PR", ibge_code: "4106902")

    expect(described_class.current).to eq(profile)
  end

  it "validates name, UF and IBGE code" do
    expect(described_class.new(name: "", uf: "PR")).not_to be_valid
    expect(described_class.new(name: "X", uf: "pr")).not_to be_valid
    expect(described_class.new(name: "X", ibge_code: "123")).not_to be_valid
    expect(described_class.new(name: "X", uf: "PR", ibge_code: "4106902")).to be_valid
  end
end
