require "rails_helper"

# api#27: o dia, os prazos e as janelas da cidade seguem o fuso DELA, não um
# fuso fixo. O Brasil tem 4 fusos (UTC-2 a UTC-5) e 16 identificadores IANA.
RSpec.describe "Fuso da cidade" do
  it "nasce em America/Sao_Paulo" do
    expect(build(:city).time_zone).to eq("America/Sao_Paulo")
  end

  it "aceita os fusos IANA do Brasil e recusa os de fora" do
    expect(City::TIME_ZONES).to include("America/Noronha", "America/Sao_Paulo", "America/Manaus", "America/Rio_Branco")
    expect(City::TIME_ZONES.size).to eq(16)
    expect(build(:city, time_zone: "America/Manaus")).to be_valid
    %w[Europe/Lisbon UTC Brasilia].each do |tz|
      city = build(:city, time_zone: tz)
      expect(city).not_to be_valid
      expect(city.errors[:time_zone]).to be_present
    end
  end

  it "o banco recusa nascer com fuso fora da lista, mesmo por insert_all" do
    row = build(:city).attributes.except("id", "created_at", "updated_at").merge("time_zone" => "Europe/Lisbon")
    expect do
      PlatformRecord.transaction(requires_new: true) { City.insert_all!([ row ]) }
    end.to raise_error(ActiveRecord::StatementInvalid, /ck_cities_time_zone/)
  end

  # Decisão do usuário (2026-10-02, api#36): o fuso de uma cidade é definido no
  # provisionamento e não muda. O trigger de db/platform_triggers.sql garante.
  it "o banco recusa trocar o fuso de uma cidade, mesmo por update_all" do
    city = create(:city, time_zone: "America/Manaus")
    expect do
      PlatformRecord.transaction(requires_new: true) do
        City.where(id: city.id).update_all(time_zone: "America/Sao_Paulo")
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /cities.time_zone is set once/)
    expect { city.update!(name: "Outro nome", status: "active") }.not_to raise_error
    expect(city.reload.time_zone).to eq("America/Manaus")
  end

  describe "CityConnection.with" do
    it "troca o fuso pelo da cidade e devolve o anterior na saída" do
      manaus = TEST_CITY_A.dup.tap { |c| c.time_zone = "America/Manaus" }
      expect(Time.zone.name).to eq("America/Sao_Paulo")
      CityConnection.with(manaus) do
        expect(Time.zone.name).to eq("America/Manaus")
        CityConnection.with(TEST_CITY_A) { expect(Time.zone.name).to eq("America/Sao_Paulo") }
        expect(Time.zone.name).to eq("America/Manaus")
      end
      expect(Time.zone.name).to eq("America/Sao_Paulo")
    end

    it "o 'hoje' da cidade vira à meia-noite local" do
      manaus = TEST_CITY_A.dup.tap { |c| c.time_zone = "America/Manaus" }
      instant = Time.utc(2026, 10, 3, 3, 30) # 00:30 em São Paulo, 23:30 do dia 2 em Manaus
      CityConnection.with(TEST_CITY_A) { expect(instant.in_time_zone.to_date).to eq(Date.new(2026, 10, 3)) }
      CityConnection.with(manaus) { expect(instant.in_time_zone.to_date).to eq(Date.new(2026, 10, 2)) }
    end
  end
end
