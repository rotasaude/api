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

  # Resíduo do Plano 4 (Task 1): só falha de CONEXÃO merece mensagem
  # publicada. Qualquer outra exceção é texto sem controle — pode carregar
  # dado de cidadão de um bug de interpolação — e sai só pelo nome da classe.
  it "reports a non-connection failure by its class only, never its message" do
    expect {
      described_class.call(city) { raise ArgumentError, "telefone +55 41 99999-0000 inválido" }
    }.to raise_error(described_class::Failed) { |e|
      expect(e.message).to eq("ArgumentError")
      expect(e.message).not_to include("99999")
    }
  end

  it "logs a non-connection failure by its class, without the raw message" do
    logged = []
    allow(Rails.logger).to receive(:warn) { |msg| logged << msg }

    expect { described_class.call(city) { raise ArgumentError, "telefone +55 41 99999-0000" } }
      .to raise_error(described_class::Failed)

    expect(logged.join).to include("ArgumentError")
    expect(logged.join).not_to include("99999")
  end

  it "still treats every class in CityConnectionErrors as unreachable, with a redacted message" do
    Maintenance::CityConnectionErrors::CLASSES.each do |klass|
      allow(CityConnection).to receive(:with)
        .and_raise(klass.new("connection to postgres://rota_city_x:s3nha@db:5432/x failed"))

      expect { described_class.call(city) { :never } }
        .to raise_error(described_class::Unreachable) { |e| expect(e.message).not_to include("s3nha") }
    end
  end

  # Fix round 1: a conexão que cai NO MEIO de uma query (não ao tentar abrir)
  # sai do adapter de Postgres do Rails como ActiveRecord::ConnectionFailed
  # (< QueryAborted < StatementInvalid), não como ConnectionNotEstablished —
  # sem esta classe na lista, essa cidade virava CITY_READ_FAILED em vez de
  # CITY_UNREACHABLE.
  it "treats a connection dropped mid-query as unreachable, not as a read failure" do
    allow(CityConnection).to receive(:with)
      .and_raise(ActiveRecord::ConnectionFailed, "server closed the connection unexpectedly")

    expect { described_class.call(city) { :never } }.to raise_error(described_class::Unreachable)
  end
end
