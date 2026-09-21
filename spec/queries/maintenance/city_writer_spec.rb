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
      .to raise_error(described_class::Unreachable) do |e|
        expect(e.message).not_to include("s3nha")
        expect(e).not_to be_started
      end
  end

  # Spec §9: a conexão que cai com o bloco já rodando deixa o resultado
  # desconhecido — quem chama precisa saber a diferença.
  it "marks a connection failure raised by the block as started" do
    expect { described_class.call(city) { raise ActiveRecord::ConnectionFailed, "postgres://u:s3nha@db/x gone" } }
      .to raise_error(described_class::Unreachable) do |e|
        expect(e).to be_started
        expect(e.message).not_to include("s3nha")
      end
  end

  # Tetos de espera só na escrita: o bloco roda numa transação que já traz
  # lock_timeout/statement_timeout locais a ela.
  it "runs the block in a transaction bounded by lock_timeout and statement_timeout" do
    settings = described_class.call(city) do
      connection = CityRecord.lease_connection
      [ connection.transaction_open?, connection.select_value("SHOW lock_timeout"),
        connection.select_value("SHOW statement_timeout") ]
    end

    expect(settings).to eq([ true, described_class::LOCK_TIMEOUT, described_class::STATEMENT_TIMEOUT ])
    expect(settings.drop(1)).to eq(%w[5s 10s])
  end

  # A transação de fora não é "joinable": a transação do próprio command vira
  # SAVEPOINT, e o `raise ActiveRecord::Rollback` dele desfaz o que ele
  # escreveu (juntando-se à de fora, o Rollback seria engolido e a escrita
  # ficaria).
  it "keeps a command's own transaction a savepoint, so its Rollback still undoes its writes" do
    kept = described_class.call(city) do
      ApplicationRecord.transaction do
        ProtocolDefinition.create!(name: "savepoint-probe", version: 1,
                                   definition: protocol_definition_hash(name: "savepoint-probe", version: 1))
        raise ActiveRecord::Rollback
      end
      ProtocolDefinition.where(name: "savepoint-probe").count
    end

    expect(kept).to eq(0)
  end

  it "lets any other exception raised by the block go up untouched" do
    expect { described_class.call(city) { raise ArgumentError, "bug" } }.to raise_error(ArgumentError, "bug")
  end
end
