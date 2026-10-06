# spec/services/ledi/transport_spec.rb
require "rails_helper"

# Spec §6.2: DadoTransporteThrift com uuid CNES-UUID, tipo, CNES, codIbge (do
# city_profile da cidade), INE, remetente/originadora com contraChave
# "Rota Saúde - <versão>", uuidInstalacao estável por cidade, CNPJ do
# responsável e a versão 8.7.0.
RSpec.describe Ledi::Transport do
  let(:city) { register_test_city! }
  let(:uuid) { "1234567-#{SecureRandom.uuid}" }
  let(:ficha) do
    Ledi::Fichas::Synthetic.new(cnes: "1234567", ine: "0000123456", professional_cns: "700000000000005",
                                cbo: "225142", attended_at: Time.zone.parse("2026-10-06 10:00"),
                                source_id: SecureRandom.uuid)
  end

  before { CityProfile.create!(name: "Maringá", ibge_code: "4115200") }

  it "monta o transporte com a ficha serializada dentro" do
    transport = described_class.read(described_class.wrap(ficha, city: city, uuid: uuid))

    expect(transport.uuidDadoSerializado).to eq(uuid)
    expect(transport.tipoDadoSerializado).to eq(7)
    expect(transport.cnesDadoSerializado).to eq("1234567")
    expect(transport.codIbge).to eq("4115200")
    expect(transport.ineDadoSerializado).to eq("0000123456")
    expect(transport.numLote).to be_nil
    expect([ transport.versao.major, transport.versao.minor, transport.versao.revision ]).to eq([ 8, 7, 0 ])
    inner = Ledi::Version.deserialize(Ledi::FichaTypes.klass("procedimento"), transport.dadoSerializado)
    expect(inner.uuidFicha).to eq(uuid)
  end

  it "remetente e originadora identificam o Rota Saúde com uuid estável por cidade" do
    transport = described_class.read(described_class.wrap(ficha, city: city, uuid: uuid))
    again = described_class.read(described_class.wrap(ficha, city: city, uuid: "1234567-#{SecureRandom.uuid}"))
    other = described_class.read(described_class.wrap(ficha, city: build(:city, id: SecureRandom.uuid), uuid: uuid))

    expect(transport.remetente).to eq(transport.originadora)
    expect(transport.remetente.contraChave).to eq("Rota Saúde - #{Ledi::Sender.software_version}")
    expect(transport.remetente.cpfOuCnpj).to eq("11222333000181")
    expect(transport.remetente.uuidInstalacao).to eq(again.remetente.uuidInstalacao)
    expect(transport.remetente.uuidInstalacao).not_to eq(other.remetente.uuidInstalacao)
  end

  it "rewrap troca o uuid do transporte e da ficha, mantendo o resto" do
    bytes = described_class.wrap(ficha, city: city, uuid: uuid)
    fresh = "1234567-#{SecureRandom.uuid}"
    transport = described_class.read(described_class.rewrap(bytes, uuid: fresh))

    expect(transport.uuidDadoSerializado).to eq(fresh)
    expect(Ledi::Version.deserialize(Ledi::FichaTypes.klass("procedimento"), transport.dadoSerializado).uuidFicha)
      .to eq(fresh)
    expect(transport.cnesDadoSerializado).to eq("1234567")
  end

  it "sem IBGE no city_profile: IbgeMissing" do
    CityProfile.current.update!(ibge_code: nil)
    expect { described_class.wrap(ficha, city: city, uuid: uuid) }.to raise_error(Ledi::Transport::IbgeMissing)
  end

  it "remetente sem CNPJ configurado: Sender::Missing" do
    allow(Rails.application).to receive(:config_for).and_call_original
    allow(Rails.application).to receive(:config_for).with(:ledi).and_return({ sender_cnpj: "", sender_name: "" })
    expect { described_class.wrap(ficha, city: city, uuid: uuid) }.to raise_error(Ledi::Sender::Missing)
  end

  it "tipo desconhecido: UnknownType" do
    expect { Ledi::FichaTypes.code("vacinacao") }.to raise_error(Ledi::FichaTypes::UnknownType)
  end
end
