require "rails_helper"

RSpec.describe CityPublicUrl do
  let(:city) { City.new(slug: "curitiba", name: "Curitiba", status: "active") }

  it "derives base, dashboard and wpda from the slug" do
    expect(described_class.base(city)).to eq("http://curitiba.localhost:5175")
    expect(described_class.dashboard(city)).to eq("http://curitiba.localhost:5175/dashboard/")
    expect(described_class.wpda(city)).to eq("http://curitiba.localhost:5175/wpda/")
  end

  it "honours CITY_PUBLIC_BASE_TEMPLATE and never doubles the slash" do
    # Mesmo padrão de spec/services/city_database_spec.rb:43-46 (stub de ENV com
    # and_call_original): não há gem de env var na suíte.
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch)
      .with("CITY_PUBLIC_BASE_TEMPLATE", described_class::DEFAULT_TEMPLATE)
      .and_return("https://%{slug}.rota-saude.example/")

    expect(described_class.base(city)).to eq("https://curitiba.rota-saude.example")
    expect(described_class.dashboard(city)).to eq("https://curitiba.rota-saude.example/dashboard/")
  end

  it "raises instead of building a link without a city" do
    expect { described_class.base(nil) }.to raise_error(CityPublicUrl::CityMissing)
  end

  it "uses CITY_WPDA_BASE_TEMPLATE for the wpda link when present, leaving base/dashboard on the public template" do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CITY_WPDA_BASE_TEMPLATE")
      .and_return("http://%{slug}.localhost:5176")

    expect(described_class.wpda(city)).to eq("http://curitiba.localhost:5176/wpda/")
    expect(described_class.base(city)).to eq("http://curitiba.localhost:5175")
    expect(described_class.dashboard(city)).to eq("http://curitiba.localhost:5175/dashboard/")
  end
end
