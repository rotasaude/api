# spec/services/ledi/fichas/individual_care_spec.rb
require "rails_helper"

# ADR 0031 (spec §6; Task 1): consulta → Atendimento Individual contra os
# IDLs 8.7.0 — tipo, problemas com situação e uuids, condutas, exames
# solicitados, medições; só CPF; sem medicamento nem texto.
RSpec.describe Ledi::Fichas::IndividualCare do
  let(:started) { Time.zone.parse("2026-10-07 09:10") }
  let(:identity) do
    Ledi::Fichas::ScreeningIdentity.new(cnes: "1234567", ine: "0000123456", professional_cns: "700000000000005",
                                        cbo: "225125", citizen_cpf: "52998224725", birth_date: Date.new(1980, 5, 10),
                                        sex: "female", started_at: started, ended_at: started + 20.minutes, ibge_code: "4106902")
  end
  let(:problems) do
    [ described_class::Problem.new(uuid: "p-1", evolution_uuid: "e-1", sequence: 1, ciap: "T90", cid10: nil, situation: 0,
                                   onset_on: Date.new(2025, 8, 1), resolved_on: nil),
      described_class::Problem.new(uuid: "p-2", evolution_uuid: "e-2", sequence: 3, ciap: nil, cid10: "N390", situation: 2,
                                   onset_on: nil, resolved_on: Date.new(2026, 10, 7)) ]
  end
  let(:measurements) { ScreeningRevision.new(systolic: 130, diastolic: 85, weight_kg: BigDecimal("82.5"), height_cm: 170) }
  let(:care) { described_class::Care.new(care_type: 5, problems: problems, conducts: [ 1, 9 ], exams: [ "0202010503" ], measurements: measurements) }
  let(:ficha) { described_class.new(identity: identity, care: care, source_id: "f0f0f0f0-0000-4000-8000-000000000009") }
  def ms(time) = (time.to_f * 1000).to_i

  it "cumpre a interface Ledi::Ficha" do
    expect { Ledi::Ficha.assert!(ficha) }.not_to raise_error
    expect([ ficha.type, ficha.competence, ficha.cnes, ficha.ine ]).to eq([ "atendimento_individual", "202610", "1234567", "0000123456" ])
    expect(ficha.source).to eq(type: "Consultation", id: "f0f0f0f0-0000-4000-8000-000000000009")
  end

  it "monta o MIAI da consulta" do
    master = ficha.to_thrift(uuid: "1234567-c")
    expect([ master.uuidFicha, master.tpCdsOrigem ]).to eq([ "1234567-c", 3 ])
    lotacao = master.headerTransport.lotacaoFormPrincipal
    expect([ lotacao.profissionalCNS, lotacao.cboCodigo_2002, lotacao.cnes, lotacao.ine ]).to eq(%w[700000000000005 225125 1234567 0000123456])
    child = master.atendimentosIndividuais.sole
    expect([ child.tipoAtendimento, child.localDeAtendimento, child.turno, child.sexo, child.condutas ]).to eq([ 5, 1, 1, 1, [ 1, 9 ] ])
    expect([ child.cpfCidadao, child.cns, child.stCidadaoNaoPossuiCpf, child.medicamentos ]).to eq([ "52998224725", nil, false, nil ])
    expect([ child.dataHoraInicialAtendimento, child.dataHoraFinalAtendimento ]).to eq([ ms(started), ms(started + 20.minutes) ])
    first, second = child.problemasCondicoes
    expect([ first.uuidProblema, first.uuidEvolucaoProblema, first.coSequencialEvolucao, first.ciap, first.cid10, first.situacao,
             first.dataInicioProblema, first.dataFimProblema, first.isAvaliado ])
      .to eq([ "p-1", "e-1", 1, "T90", nil, 0, ms(Date.new(2025, 8, 1).in_time_zone), nil, true ])
    expect([ second.ciap, second.cid10, second.situacao, second.dataFimProblema ])
      .to eq([ nil, "N390", 2, ms(Date.new(2026, 10, 7).in_time_zone) ])
    exam = child.exame.sole
    expect([ exam.codigoExame, exam.solicitadoAvaliado ]).to eq([ "0202010503", [ "S" ] ])
    expect([ child.medicoes.pressaoArterialSistolica, child.medicoes.peso ]).to eq([ 130, 82.5 ])
    expect { master.validate }.not_to raise_error
    expect(Ledi::Version.deserialize(master.class, Ledi::Version.serialize(master))).to eq(master)
  end

  it "sem exame nem medição: os campos ficam fora" do
    bare = described_class::Care.new(care_type: 2, problems: problems.first(1), conducts: [ 9 ], exams: [], measurements: nil)
    child = described_class.new(identity: identity, care: bare, source_id: SecureRandom.uuid).to_thrift(uuid: "x").atendimentosIndividuais.sole
    expect([ child.exame, child.medicoes, child.tipoAtendimento ]).to eq([ nil, nil, 2 ])
  end

  # Decisão do usuário (2026-10-08): CID-10 só de médico, como no PEC — na
  # consulta de não médico a ficha omite o problema avaliado em CID-10 e manda
  # só os CIAP-2 (o prontuário não muda); os valores de cada item enviado ficam.
  it "consulta de enfermeira: o problema em CID-10 fica fora, o CIAP-2 vai" do
    nurse = identity.with(cbo: "223505")
    sent = described_class.new(identity: nurse, care: care, source_id: SecureRandom.uuid).to_thrift(uuid: "x")
                          .atendimentosIndividuais.sole.problemasCondicoes
    expect(sent.map { |p| [ p.uuidProblema, p.coSequencialEvolucao, p.ciap, p.cid10 ] }).to eq([ [ "p-1", 1, "T90", nil ] ])
  end

  it "consulta de médico: o problema em CID-10 vai" do
    sent = ficha.to_thrift(uuid: "x").atendimentosIndividuais.sole.problemasCondicoes
    expect(sent.map(&:cid10)).to eq([ nil, "N390" ])
  end

  # Regra LEDI: dataInicioProblema >= nascimento. Início com precisão de mês
  # grava o dia 1, que pode cair antes do nascimento no mesmo mês.
  it "o início do problema nunca fica antes do nascimento" do
    young = identity.with(birth_date: Date.new(2000, 6, 15))
    early = problems.first.with(onset_on: Date.new(2000, 6, 1))
    bare = described_class::Care.new(care_type: 2, problems: [ early ], conducts: [ 9 ], exams: [], measurements: nil)
    sent = described_class.new(identity: young, care: bare, source_id: SecureRandom.uuid).to_thrift(uuid: "x")
                          .atendimentosIndividuais.sole.problemasCondicoes.sole
    expect(sent.dataInicioProblema).to eq(ms(Date.new(2000, 6, 15).in_time_zone))
  end
end
