require "rails_helper"

RSpec.describe "City test database harness" do
  it "runs every example inside the default test city's connection" do
    expect(CityRecord.connection_db_config.database).to eq("rota_saude_test_city_a")
  end

  it "rolls back writes between examples" do
    expect(CityHarnessProbe.count).to eq(0)
    CityHarnessProbe.create!(label: "efêmero")
    expect(CityHarnessProbe.count).to eq(1)
  end

  it "rolls back writes between examples (second example proves the first rolled back)" do
    expect(CityHarnessProbe.count).to eq(0)
  end

  it "can switch to the second city with within_city" do
    within_city(TEST_CITY_B) do
      expect(CityRecord.connection_db_config.database).to eq("rota_saude_test_city_b")
    end
    expect(CityRecord.connection_db_config.database).to eq("rota_saude_test_city_a")
  end
end
