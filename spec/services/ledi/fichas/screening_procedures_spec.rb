require "rails_helper"

# ADR 0030 (spec §5; Task 1): escuta por técnico/auxiliar de enfermagem →
# Ficha de Procedimentos com a marca de escuta; o código 03.01.04.007-9 nunca
# vai na lista. Decisão D10 do product owner (2026-10-07, substitui spec §5):
# sem aferição a ficha AINDA nasce, só com statusEscutaInicialOrientacao = true.
RSpec.describe Ledi::Fichas::ScreeningProcedures do
  let(:started) { Time.zone.parse("2026-10-07 19:30") }
  let(:identity) do
    Ledi::Fichas::ScreeningIdentity.new(cnes: "1234567", ine: nil, professional_cns: "700000000000005", cbo: "322205",
                                        citizen_cpf: "52998224725", birth_date: Date.new(1950, 1, 2), sex: "male",
                                        started_at: started, ended_at: started + 8.minutes, ibge_code: "4106902")
  end

  def revision(**attrs) = ScreeningRevision.new({ ciap2_code: "K86", final_color: "yellow" }.merge(attrs))

  it "procedimentos das aferições feitas, na ordem do mapeamento; sem aferição ainda se aplica (D10)" do
    full = revision(systolic: 150, diastolic: 95, capillary_glucose: 210, glucose_moment: "random",
                    temperature_c: BigDecimal("38"), weight_kg: BigDecimal("70"), height_cm: 160, spo2: 96, pain_score: 3)
    expect(described_class.procedures(full)).to eq(%w[0301100039 0214010015 0301100250 0101040083 0101040075])
    expect(described_class.procedures(revision(spo2: 96, pain_score: 2))).to eq([])
    expect(described_class.applicable?(revision(spo2: 96, pain_score: 2))).to be(true)
    expect(described_class.applicable?(revision)).to be(true)
    expect(described_class.applicable?(revision(systolic: 120, diastolic: 80))).to be(true)
  end

  it "monta o MIP com a marca de escuta, medições, sem o código da escuta e só CPF" do
    rev = revision(systolic: 150, diastolic: 95)
    ficha = described_class.new(identity: identity, revision: rev, source_id: "f0f0f0f0-0000-4000-8000-000000000002")
    expect { Ledi::Ficha.assert!(ficha) }.not_to raise_error
    expect([ ficha.type, ficha.ine ]).to eq([ "procedimento", nil ])
    master = ficha.to_thrift(uuid: "1234567-p")
    header = master.headerTransport
    expect(header).to be_a(Br::Gov::Saude::Esusab::Ras::Common::UnicaLotacaoHeaderThrift)
    expect([ header.profissionalCNS, header.cboCodigo_2002, header.cnes, header.ine ]).to eq([ "700000000000005", "322205", "1234567", nil ])
    child = master.atendProcedimentos.sole
    expect([ child.statusEscutaInicialOrientacao, child.procedimentos, child.localAtendimento, child.turno, child.sexo ])
      .to eq([ true, [ "0301100039" ], 1, 3, 0 ])
    expect([ child.cpfCidadao, child.cnsCidadao, child.stCidadaoNaoPossuiCpf ]).to eq([ "52998224725", nil, false ])
    expect([ child.medicoes.pressaoArterialSistolica, child.medicoes.pressaoArterialDiastolica ]).to eq([ 150, 95 ])
    expect(child.procedimentos).not_to include(Ledi::ScreeningMapping.value("screening_procedures.forbidden_procedure"))
    expect { master.validate }.not_to raise_error
  end

  # D10 + screening_procedures.flag_only_accepted: técnico sem aferição → MIP só
  # com a marca; procedimentos e medicoes ficam ausentes (nil), não listas vazias.
  it "sem aferição: MIP só com a marca de escuta, sem procedimentos nem medicoes, e serializa" do
    expect(Ledi::ScreeningMapping.value("screening_procedures.flag_only_accepted")).to be(true)
    ficha = described_class.new(identity: identity, revision: revision, source_id: "f0f0f0f0-0000-4000-8000-000000000003")
    expect { Ledi::Ficha.assert!(ficha) }.not_to raise_error
    master = ficha.to_thrift(uuid: "1234567-f")
    expect(master.headerTransport).to be_a(Br::Gov::Saude::Esusab::Ras::Common::UnicaLotacaoHeaderThrift)
    child = master.atendProcedimentos.sole
    expect([ child.statusEscutaInicialOrientacao, child.procedimentos, child.medicoes ]).to eq([ true, nil, nil ])
    expect(child.procedimentos?).to be(false)
    expect(child.medicoes?).to be(false)
    expect { master.validate }.not_to raise_error

    bytes = Ledi::Version.serialize(master)
    back = Ledi::Version.deserialize(master.class, bytes)
    expect(back).to eq(master)
    read_child = back.atendProcedimentos.sole
    expect([ read_child.statusEscutaInicialOrientacao, read_child.procedimentos, read_child.medicoes ]).to eq([ true, nil, nil ])
  end

  # SpO2/dor não têm SIGTAP: sem procedimento, mas a SpO2 vai nas medicoes.
  it "só SpO2 e dor: sem procedimentos, medicoes só com a SpO2" do
    child = described_class.new(identity: identity, revision: revision(spo2: 96, pain_score: 2), source_id: SecureRandom.uuid)
                           .to_thrift(uuid: "x").atendProcedimentos.sole
    expect([ child.statusEscutaInicialOrientacao, child.procedimentos, child.medicoes.saturacaoO2 ]).to eq([ true, nil, 96 ])
  end
end
