require "rails_helper"

# A leitura de dentro da cidade é sondagem: erro daqui é diagnóstico, não
# motivo para a resposta inteira falhar (mesma regra de CityInventory).
RSpec.describe Maintenance::CityReader do
  # P1/P2: sem constante de topo; a cidade é arranjada explicitamente, no
  # mesmo padrão de spec/requests/maintenance/city_spec.rb. O harness não
  # seeda nenhuma City de plataforma sozinho — `City.active.first` do brief
  # respondia nil neste spec isolado (achado ao rodar RED) — então
  # registramos TEST_CITY_A (reentra a MESMA sessão que o `around` global já
  # abriu) e uma cidade arquivada de verdade, em vez de depender de estado
  # alheio ou de `skip` como caminho esperado.
  def register_city!(test_city)
    return City.find_by(slug: test_city.slug) if City.exists?(slug: test_city.slug)

    City.create!(slug: test_city.slug, name: test_city.name, status: "active",
                database_url: test_city.database_url, encryption_key: test_city.encryption_key,
                schema_version: CitySchema.expected_version.to_s)
  end

  let!(:city) { register_city!(TEST_CITY_A) }

  let!(:archived) do
    City.create!(slug: "arquivada-#{SecureRandom.hex(3)}", name: "Cidade Arquivada", uf: "sp",
                status: "archived", schema_version: "0",
                # Arquivada não abre conexão — a URL nunca é discada, e é de
                # propósito claramente não roteável.
                database_url: "postgres://unreachable.invalid/none",
                encryption_key: SecureRandom.hex(32))
  end

  it "runs the block inside the city's connection" do
    result = described_class.call(city) { CityProfile.current&.name || :sem_perfil }

    expect(result).not_to be_nil
  end

  it "answers Archived for a city whose database is gone, without connecting" do
    expect(CityConnection).not_to receive(:with)

    expect { described_class.call(archived) { CityProfile.current } }
      .to raise_error(described_class::Archived)
  end

  it "wraps a connection failure and redacts the credential from the message" do
    allow(CityConnection).to receive(:with)
      .and_raise(PG::ConnectionBad, "connection to postgres://rota_city_x:s3nha@db:5432/rota_saude_city_x failed")

    expect { described_class.call(city) { CityProfile.current } }
      .to raise_error(described_class::Unreachable) { |e|
        expect(e.message).to include("PG::ConnectionBad")
        expect(e.message).to include("://***@")
        expect(e.message).not_to include("s3nha")
      }
  end

  # T3 (achado na revisão final do Plano 4): sem isto, um bug de código real
  # (não uma cidade de fato inalcançável) some dentro de CITY_UNREACHABLE sem
  # rastro nenhum fora da resposta GraphQL redigida.
  it "logs the exception class and the redacted message, never the raw one" do
    logged = nil
    allow(Rails.logger).to receive(:warn) { |message| logged = message }
    allow(CityConnection).to receive(:with)
      .and_raise(PG::ConnectionBad, "connection to postgres://rota_city_x:s3nha@db:5432/rota_saude_city_x failed")

    expect { described_class.call(city) { CityProfile.current } }.to raise_error(described_class::Unreachable)

    expect(logged).to include("PG::ConnectionBad")
    expect(logged).to include("://***@")
    expect(logged).not_to include("s3nha")
  end
end
