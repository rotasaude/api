require "rails_helper"

# ADR 0030 (spec §5; Task 1): escuta por nível superior → Atendimento
# Individual, tipo 4 (escuta inicial), contra os IDLs 8.7.0.
RSpec.describe Ledi::Fichas::InitialListening do
  let(:started) { Time.zone.parse("2026-10-07 09:10") }
  let(:identity) do
    Ledi::Fichas::ScreeningIdentity.new(cnes: "1234567", ine: "0000123456", professional_cns: "700000000000005",
                                        cbo: "223505", citizen_cpf: "52998224725", birth_date: Date.new(1980, 5, 10),
                                        sex: "female", started_at: started, ended_at: started + 12.minutes,
                                        ibge_code: "4106902")
  end
  let(:revision) do
    ScreeningRevision.new(ciap2_code: "K86", systolic: 185, diastolic: 110, heart_rate: 92, respiratory_rate: 18,
                          temperature_c: BigDecimal("37.2"), spo2: 97, capillary_glucose: 110, glucose_moment: "fasting",
                          weight_kg: BigDecimal("80.5"), height_cm: 175, pain_score: 6, final_color: "red")
  end
  let(:ficha) { described_class.new(identity: identity, revision: revision, destination: "same_day", source_id: "f0f0f0f0-0000-4000-8000-000000000001") }
  def ms(time) = (time.to_f * 1000).to_i

  it "cumpre a interface Ledi::Ficha" do
    expect { Ledi::Ficha.assert!(ficha) }.not_to raise_error
    expect([ ficha.type, ficha.competence, ficha.cnes, ficha.ine ]).to eq([ "atendimento_individual", "202610", "1234567", "0000123456" ])
    expect(ficha.source).to eq(type: "Screening", id: "f0f0f0f0-0000-4000-8000-000000000001")
    expect(Ledi::FichaTypes.code(ficha.type)).to eq(4)
  end

  # Preflight F13: o código do registro bate com o mapeamento (fonte única).
  it "o tipoDadoSerializado do registro é o do mapeamento" do
    expect(Ledi::FichaTypes.code("atendimento_individual"))
      .to eq(Ledi::ScreeningMapping.value("tipo_dado_serializado.atendimento_individual"))
    expect(Ledi::FichaTypes.code("procedimento")).to eq(Ledi::ScreeningMapping.value("tipo_dado_serializado.procedimento"))
    expect(Ledi::FichaTypes::REGISTRY["atendimento_individual"])
      .to eq(code: 4, klass: "Br::Gov::Saude::Esusab::Ras::Atendindividual::FichaAtendimentoIndividualMasterThrift",
             uuid_field: :uuidFicha)
  end

  it "monta o MIAI: cabeçalho da lotação, escuta inicial, conduta pelo destino, CIAP-2 e medições; só CPF" do
    master = ficha.to_thrift(uuid: "1234567-u")
    expect([ master.uuidFicha, master.tpCdsOrigem ]).to eq([ "1234567-u", 3 ])
    lotacao = master.headerTransport.lotacaoFormPrincipal
    expect([ lotacao.profissionalCNS, lotacao.cboCodigo_2002, lotacao.cnes, lotacao.ine ])
      .to eq(%w[700000000000005 223505 1234567 0000123456])
    expect([ master.headerTransport.dataAtendimento, master.headerTransport.codigoIbgeMunicipio ]).to eq([ ms(started), "4106902" ])
    child = master.atendimentosIndividuais.sole
    expect([ child.tipoAtendimento, child.localDeAtendimento, child.turno, child.sexo ]).to eq([ 4, 1, 1, 1 ])
    expect(child.condutas).to eq([ 11 ])
    expect([ child.cpfCidadao, child.cns, child.stCidadaoNaoPossuiCpf ]).to eq([ "52998224725", nil, false ])
    expect(child.dataNascimento).to eq(ms(Date.new(1980, 5, 10).in_time_zone))
    expect([ child.dataHoraInicialAtendimento, child.dataHoraFinalAtendimento ]).to eq([ ms(started), ms(started + 12.minutes) ])
    problem = child.problemasCondicoes.sole
    expect([ problem.ciap, problem.isAvaliado ]).to eq([ "K86", true ])
    m = child.medicoes
    expect([ m.pressaoArterialSistolica, m.pressaoArterialDiastolica, m.frequenciaCardiaca, m.frequenciaRespiratoria,
             m.temperatura, m.saturacaoO2, m.glicemiaCapilar, m.tipoGlicemiaCapilar, m.peso, m.altura ])
      .to eq([ 185, 110, 92, 18, 37.2, 97, 110, 0, 80.5, 175.0 ])
    expect { master.validate }.not_to raise_error
    bytes = Ledi::Version.serialize(master)
    expect(Ledi::Version.deserialize(master.class, bytes)).to eq(master)
  end

  it "conduta por destino; turno da tarde; sem medida não há medicoes" do
    { "schedule" => 1, "oriented" => 9, "referred" => 4 }.each do |destination, code|
      other = described_class.new(identity: identity, revision: revision, destination: destination, source_id: SecureRandom.uuid)
      expect(other.to_thrift(uuid: "x").atendimentosIndividuais.sole.condutas).to eq([ code ])
    end
    afternoon = identity.with(started_at: Time.zone.parse("2026-10-07 14:00"), ended_at: Time.zone.parse("2026-10-07 14:10"))
    bare = ScreeningRevision.new(ciap2_code: "R05", final_color: "green")
    child = described_class.new(identity: afternoon, revision: bare, destination: "same_day", source_id: SecureRandom.uuid)
                           .to_thrift(uuid: "x").atendimentosIndividuais.sole
    expect([ child.turno, child.medicoes ]).to eq([ 2, nil ])
  end
end
