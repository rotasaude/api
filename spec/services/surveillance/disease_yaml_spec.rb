# spec/services/surveillance/disease_yaml_spec.rb
require "rails_helper"

RSpec.describe "Lista de notificação compulsória e ficha do Sinan (prova técnica)" do
  let(:list) { YAML.safe_load_file(Rails.root.join("config/surveillance/notifiable-diseases.yml")) }
  let(:form) { YAML.safe_load_file(Rails.root.join("config/surveillance/sinan-form.yml")) }
  let(:diseases) { list.fetch("diseases") }

  it "cabeçalho da portaria e todas as linhas válidas, com fonte" do
    expect(list["ordinance"]).to include("11.211")
    expect(Date.iso8601(list["effective_from"])).to eq(Date.new(2026, 5, 14))
    diseases.each do |d|
      expect(d["code"]).to match(Surveillance::Catalog::PLATFORM_CODE)
      expect(Surveillance::Catalog::DEADLINES.keys).to include(d["deadline"])
      expect(d["name"].length).to be_between(1, Surveillance::Catalog::NAME_MAX)
      expect(d["cid10"]).to all(match(Surveillance::Catalog::CID10))
      expect(d["ciap2"]).to all(match(Surveillance::Catalog::CIAP2))
      expect(d["repeat_after_days"]).to be_between(1, 36_500)
      expect(d.dig("sources", "deadline")).to be_present
      expect(d.dig("sources", "cid10")).to be_present.and(satisfy { |s| !s.include?("pendente") })
    end
    expect(diseases.map { |d| d["code"] }.uniq.size).to eq(diseases.size)
  end

  it "nenhum código cobre outro entre doenças (um problema dá no máximo uma doença)" do
    owners = diseases.flat_map { |d| d["cid10"].map { |c| [ c, d["code"] ] } }
    owners.combination(2).each do |(a, da), (b, db)|
      next if da == db

      expect(a.start_with?(b) || b.start_with?(a)).to be(false), "#{a} (#{da}) × #{b} (#{db})"
    end
    ciap = diseases.flat_map { |d| d["ciap2"] }
    expect(ciap.uniq.size).to eq(ciap.size)
    expect(ciap).not_to include("A77")
  end

  it "valores conferidos na prova" do
    by_code = diseases.index_by { |d| d["code"] }
    expect(by_code.fetch("dengue")).to include("deadline" => "weekly", "cid10" => [ "A90" ])
    expect(by_code.fetch("caxumba")["deadline"]).to eq("weekly")
    expect(by_code.values.select { |d| d["deadline"] == "immediate" }.map { |d| d["code"] }).to include("botulismo", "colera", "sarampo", "raiva_humana")
    expect(by_code.fetch("tuberculose")["cid10"]).to include("A15", "A16", "A17", "A18", "A19")
  end

  it "ficha: campos da NINDIV com domínio de raça/cor do Sinan (≠ BPA)" do
    fields = form.fetch("fields")
    expect(fields.fetch("race_color")["domain"]).to eq("1" => "Branca", "2" => "Preta", "3" => "Amarela", "4" => "Parda", "5" => "Indígena", "9" => "Ignorado")
    expect(fields.values.map { |f| f["type"] }.uniq - form.fetch("types")).to be_empty
    expect(fields.keys).to all(match(/\A[a-z][a-z0-9_]*\z/))
  end
end
