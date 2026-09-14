require "rails_helper"

RSpec.describe CityCatalog do
  include ActiveSupport::Testing::TimeHelpers

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

  it "never memoizes a miss, so a city created after a miss is found on the next lookup" do
    expect(described_class.find_by_host("recemnascida.rotasaude.app")).to be_nil

    create(:city, slug: "recemnascida", status: "active")

    expect(described_class.find_by_host("recemnascida.rotasaude.app")).not_to be_nil
  end

  it "expires a cached hit after the TTL, so a status change converges without a restart" do
    described_class.find_by_host("saopaulo.rotasaude.app")
    city.update_column(:status, "suspended")

    travel_to(Time.current + CityCatalog::CACHE_TTL + 1) do
      expect(described_class.find_by_host("saopaulo.rotasaude.app").status).to eq("suspended")
    end
  end

  it "bounds the number of cached entries" do
    (CityCatalog::MAX_CACHE_ENTRIES + 10).times do |n|
      described_class.send(:store, "label#{n}", city)
    end

    expect(described_class.send(:cache).size).to eq(CityCatalog::MAX_CACHE_ENTRIES)
  end

  describe ".console_host?" do
    it "is true only when the first label is admin" do
      expect(described_class.console_host?("admin.rotasaude.app")).to be(true)
      expect(described_class.console_host?("ADMIN.rotasaude.app")).to be(true)
      expect(described_class.console_host?("admin.localhost:5174")).to be(true)
      expect(described_class.console_host?("curitiba.rotasaude.app")).to be(false)
      expect(described_class.console_host?("api.rotasaude.app")).to be(false)
      expect(described_class.console_host?("")).to be(false)
      expect(described_class.console_host?(nil)).to be(false)
    end
  end
end
