require "rails_helper"

# Evidência OFFLINE (sem PEC, sem banco de cidade) de que o Ruby serializa as
# classes LEDI 8.7.0 geradas em vendor/ledi/8.7.0/gen-rb com TBinaryProtocol e
# que o resultado volta igual. A aceitação pelo PEC é a prova :pec
# (spec/integration/ledi_pec_spec.rb). Todos os valores são fictícios.
RSpec.describe "Serialização Thrift LEDI 8.7.0 (ida e volta)" do
  gen = Rails.root.join("vendor/ledi/8.7.0/gen-rb").to_s
  $LOAD_PATH.unshift(gen) unless $LOAD_PATH.include?(gen)
  require "dado_transporte_types"
  require "ficha_atendimento_procedimento_types"

  let(:ras) { Br::Gov::Saude::Esusab::Ras }
  let(:transp) { Br::Gov::Saude::Esusab::Dadotransp }
  let(:serializer) { Thrift::Serializer.new(Thrift::BinaryProtocolFactory.new) }
  let(:deserializer) { Thrift::Deserializer.new(Thrift::BinaryProtocolFactory.new) }

  let(:uuid) { "1234567-00000000-0000-4000-8000-000000000001" }
  let(:at_ms) { 1_790_000_000_000 }

  let(:child) do
    ras::Atendprocedimentos::FichaProcedimentoChildThrift.new(
      dtNascimento: 326_001_600_000, sexo: 1, localAtendimento: 1, turno: 1,
      cpfCidadao: "12345678909", stCidadaoNaoPossuiCpf: false, procedimentos: [ "0301100039" ],
      dataHoraInicialAtendimento: at_ms, dataHoraFinalAtendimento: at_ms + 600_000
    )
  end
  let(:header) do
    ras::Common::UnicaLotacaoHeaderThrift.new(
      profissionalCNS: "100000000010002", cboCodigo_2002: "225142", cnes: "1234567",
      ine: "0000000001", dataAtendimento: at_ms, codigoIbgeMunicipio: "4115200"
    )
  end
  let(:ficha) do
    ras::Atendprocedimentos::FichaProcedimentoMasterThrift.new(
      uuidFicha: uuid, tpCdsOrigem: 3, headerTransport: header, atendProcedimentos: [ child ]
    )
  end
  let(:installation) do
    transp::DadoInstalacaoThrift.new(
      contraChave: "Rota Saúde - teste", uuidInstalacao: "rota-saude-offline", cpfOuCnpj: "11222333000181",
      nomeOuRazaoSocial: "Rota Saúde dev", email: "dev@rotasaude.app"
    )
  end
  let(:ficha_bytes) { serializer.serialize(ficha) }
  let(:transport) do
    transp::DadoTransporteThrift.new(
      uuidDadoSerializado: uuid, tipoDadoSerializado: 7, cnesDadoSerializado: "1234567",
      codIbge: "4115200", ineDadoSerializado: "0000000001", dadoSerializado: ficha_bytes,
      remetente: installation, originadora: installation,
      versao: transp::VersaoThrift.new(major: 8, minor: 7, revision: 0)
    )
  end

  it "valida os campos obrigatórios gerados e serializa em binário" do
    expect { ficha.validate }.not_to raise_error
    expect { transport.validate }.not_to raise_error

    bytes = serializer.serialize(transport)
    expect(bytes.encoding).to eq(Encoding::BINARY)
    expect(ficha_bytes.encoding).to eq(Encoding::BINARY)
    expect(bytes.bytesize).to be > ficha_bytes.bytesize
  end

  it "o DadoTransporteThrift volta igual, e a ficha interna também" do
    back = deserializer.deserialize(transp::DadoTransporteThrift.new, serializer.serialize(transport))

    expect(back.uuidDadoSerializado).to eq(uuid)
    expect(back.tipoDadoSerializado).to eq(7)
    expect(back.cnesDadoSerializado).to eq("1234567")
    expect(back.codIbge).to eq("4115200")
    expect(back.ineDadoSerializado).to eq("0000000001")
    expect(back.remetente).to eq(installation)
    expect(back.originadora).to eq(installation)
    expect(back.versao).to eq(transp::VersaoThrift.new(major: 8, minor: 7, revision: 0))
    expect(back.dadoSerializado.b).to eq(ficha_bytes.b)
    expect(back).to eq(transport)

    inner = deserializer.deserialize(ras::Atendprocedimentos::FichaProcedimentoMasterThrift.new, back.dadoSerializado)
    expect(inner.uuidFicha).to eq(uuid)
    expect(inner.tpCdsOrigem).to eq(3)
    expect(inner.headerTransport).to eq(header)
    expect(inner.atendProcedimentos).to eq([ child ])
    expect(inner).to eq(ficha)
  end

  it "rejeita a ficha sem uuid (campo required)" do
    expect { ras::Atendprocedimentos::FichaProcedimentoMasterThrift.new.validate }
      .to raise_error(Thrift::ProtocolException)
  end
end
