require "rails_helper"
require Rails.root.join("lib/dashboard_demo").to_s

# O dataset de demonstração precisa popular exatamente o que db:seed:demo:verify
# confere, DENTRO da conexão da cidade corrente e sem coluna de município. Roda na
# conexão padrão da suíte (TEST_CITY_A).
RSpec.describe DashboardDemo do
  it "populates every panel the verify task checks, in the current city" do
    cfg = described_class::CITIES.first

    described_class.seed_current_city(cfg)

    expect(described_class.verify_current_city(cfg[:slug])).to eq([])
  end

  it "is idempotent: a second run adds nothing" do
    cfg = described_class::CITIES.last

    first = described_class.seed_current_city(cfg)

    expect(described_class.seed_current_city(cfg)).to eq(first)
  end

  it "writes only into the connected city" do
    city_b = create(:city, slug: TEST_CITY_B.slug, database_url: city_database_url("rota_saude_test_city_b"))

    described_class.seed_current_city(described_class::CITIES.first)

    expect(CityConnection.with(city_b) { [ Conversation.count, DomainEvent.count, ReportSnapshot.count ] })
      .to eq([ 0, 0, 0 ])
  end

  it "verify! reports a dev city missing from the catalog instead of raising" do
    expect(described_class.verify!).to include("curitiba: city missing or not active in the catalog",
                                               "maringa: city missing or not active in the catalog")
  end
end
