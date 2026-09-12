require "rails_helper"

RSpec.describe CityCatalog do
  before do
    City.delete_all
    described_class.reset_cache!
  end

  let!(:city) { create(:city, slug: "saopaulo", status: "active") }

  it "finds a city by the host's first label" do
    expect(described_class.find_by_host("saopaulo.rotasaude.app")).to eq(city)
  end

  it "finds a city by host with a port" do
    expect(described_class.find_by_host("saopaulo.localhost:5175")).to eq(city)
  end

  it "returns nil for an unknown host" do
    expect(described_class.find_by_host("naoexiste.rotasaude.app")).to be_nil
  end

  it "treats reserved subdomains as platform hosts" do
    %w[admin api auth www].each do |label|
      expect(described_class.reserved_host?("#{label}.rotasaude.app")).to be(true)
    end
    expect(described_class.reserved_host?("saopaulo.rotasaude.app")).to be(false)
  end

  it "caches lookups and refreshes after reset" do
    described_class.find_by_host("saopaulo.rotasaude.app")
    city.update!(name: "Renomeada")
    expect(described_class.find_by_host("saopaulo.rotasaude.app").name).not_to eq("Renomeada")
    described_class.reset_cache!
    expect(described_class.find_by_host("saopaulo.rotasaude.app").name).to eq("Renomeada")
  end

  it "exposes the shard name as a symbol" do
    expect(city.shard).to eq(:saopaulo)
  end

  it "is servable only when active" do
    expect(city).to be_servable
    city.update!(status: "suspended")
    expect(city).not_to be_servable
  end

  it "stores database_url and encryption_key encrypted at rest" do
    raw = City.connection.select_one(
      City.sanitize_sql(["SELECT database_url, encryption_key FROM cities WHERE id = ?", city.id])
    )
    expect(raw["database_url"]).not_to eq(city.database_url)
    expect(raw["encryption_key"]).not_to eq(city.encryption_key)
    expect(City.find(city.id).database_url).to eq(city.database_url)
  end
end
