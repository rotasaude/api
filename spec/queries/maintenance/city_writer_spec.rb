require "rails_helper"

# A escrita entra no banco da cidade por UM lugar. Diferente da leitura, uma
# exceção de dentro do command NÃO vira "cidade inalcançável": ela sobe, e a
# mutation a registra como `error`. Só falha de conexão vira Unreachable.
RSpec.describe Maintenance::CityWriter do
  # Mesmo arranjo de spec/queries/maintenance/city_reader_spec.rb: TEST_CITY_A
  # registrada no catálogo de plataforma, reentrando a MESMA sessão que o
  # `around` global já abriu.
  def register_city!(test_city)
    return City.find_by(slug: test_city.slug) if City.exists?(slug: test_city.slug)

    City.create!(slug: test_city.slug, name: test_city.name, status: "active",
                database_url: test_city.database_url, encryption_key: test_city.encryption_key,
                schema_version: CitySchema.expected_version.to_s)
  end

  let!(:city) { register_city!(TEST_CITY_A) }

  it "runs the block inside the city's connection and returns its value" do
    expect(CityConnection).to receive(:with).with(city).and_call_original

    expect(described_class.call(city) { Current.city.slug }).to eq(city.slug)
  end

  it "refuses a city that is not active, without connecting" do
    %w[suspended archived provisioning].each do |status|
      other = City.new(slug: "w-#{status}", name: "W", status: status,
                       database_url: "postgres://u:p@invalid.invalid:5432/x", encryption_key: SecureRandom.hex(32))
      expect(CityConnection).not_to receive(:with)

      expect { described_class.call(other) { :never } }.to raise_error(described_class::NotWritable, /#{status}/)
    end
  end

  it "turns a connection failure into Unreachable with a redacted message" do
    allow(CityConnection).to receive(:with)
      .and_raise(PG::ConnectionBad.new("connection to postgres://rota_city_x:s3nha@db:5432/x failed"))

    expect { described_class.call(city) { :never } }
      .to raise_error(described_class::Unreachable) { |e| expect(e.message).not_to include("s3nha") }
  end

  it "lets any other exception raised by the block go up untouched" do
    expect { described_class.call(city) { raise ArgumentError, "bug" } }.to raise_error(ArgumentError, "bug")
  end
end
