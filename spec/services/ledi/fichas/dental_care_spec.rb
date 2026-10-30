# spec/services/ledi/fichas/dental_care_spec.rb
require "rails_helper"

# Módulo 28 (ADR 0046; F-28.2; contrato §16 O19): consulta odontológica →
# Atendimento Odontológico Individual (FAO) contra o IDL 8.7.0 —
# procedimentos agregados por SIGTAP, gestante omitido no masculino, CPF ou
# CNS (nunca os dois), tipo de consulta como lista de 0–1, CID-10 só do
# dentista; tipo 5 no transporte.
RSpec.describe Ledi::Fichas::DentalCare do
  let(:started) { Time.zone.parse("2026-10-30 14:10") }
  let(:identity) do
    Ledi::Fichas::ScreeningIdentity.new(cnes: "1234567", ine: "0001234571", professional_cns: "700000000000005",
                                        cbo: "223208", citizen_cpf: "52998224725", citizen_cns: nil, birth_date: Date.new(1980, 5, 10),
                                        sex: "female", started_at: started, ended_at: started + 30.minutes, ibge_code: "4106902")
  end
  let(:problems) do
    [ Ledi::Fichas::IndividualCare::Problem.new(uuid: "p-1", evolution_uuid: "e-1", sequence: 1, ciap: "D82", cid10: nil,
                                                situation: 0, onset_on: Date.new(2026, 9, 1), resolved_on: nil),
      Ledi::Fichas::IndividualCare::Problem.new(uuid: "p-2", evolution_uuid: "e-2", sequence: 1, ciap: nil, cid10: "K021",
                                                situation: 0, onset_on: nil, resolved_on: nil) ]
  end
  let(:procedures) { [ [ "0307010031", 1 ], [ "0307030059", 2 ], [ "0307010031", 1 ], [ "0307010031", 1 ] ] }
  let(:care) do
    described_class::Care.new(care_type: 2, consultation_type: 1, surveillance: [ 99 ], supplies: [ 1, 3 ], outcomes: [ 16 ],
                              pregnant: false, special_needs: true, procedures: procedures, problems: problems,
                              exams: [ "0204010179" ], measurements: ScreeningRevision.new(systolic: 120, diastolic: 80))
  end
  let(:ficha) { described_class.new(identity: identity, care: care, source_id: "f0f0f0f0-0000-4000-8000-000000000028") }

  def child_of(ficha) = ficha.to_thrift(uuid: "1234567-x").atendimentosOdontologicos.sole
  def ms(time) = (time.to_f * 1000).to_i

  it "cumpre a interface Ledi::Ficha; o transporte é o tipo 5" do
    expect { Ledi::Ficha.assert!(ficha) }.not_to raise_error
    expect([ ficha.type, ficha.competence, ficha.cnes, ficha.ine ]).to eq([ "atendimento_odontologico", "202610", "1234567", "0001234571" ])
    expect(ficha.source).to eq(type: "Consultation", id: "f0f0f0f0-0000-4000-8000-000000000028")
    expect(Ledi::FichaTypes.type_for_code(5)).to eq("atendimento_odontologico")
    expect(Ledi::FichaTypes.klass("atendimento_odontologico")).to eq(Br::Gov::Saude::Esusab::Ras::Atendodonto::FichaAtendimentoOdontologicoMasterThrift)
  end

  it "monta a FAO: cabeçalho, campos da consulta e procedimentos somados por SIGTAP" do
    master = ficha.to_thrift(uuid: "1234567-c")
    expect([ master.uuidFicha, master.tpCdsOrigem ]).to eq([ "1234567-c", 3 ])
    lotacao = master.headerTransport.lotacaoFormPrincipal
    expect([ lotacao.profissionalCNS, lotacao.cboCodigo_2002, lotacao.cnes, lotacao.ine ]).to eq(%w[700000000000005 223208 1234567 0001234571])
    expect(master.headerTransport.dataAtendimento).to eq(ms(started))
    child = master.atendimentosOdontologicos.sole
    expect(child.procedimentosRealizados.map { |p| [ p.coMsProcedimento, p.quantidade ] }).to eq([ [ "0307010031", 3 ], [ "0307030059", 2 ] ])
    expect([ child.tipoAtendimento, child.tiposConsultaOdonto, child.tiposVigilanciaSaudeBucal, child.tiposFornecimOdonto, child.tiposEncamOdonto ])
      .to eq([ 2, [ 1 ], [ 99 ], [ 1, 3 ], [ 16 ] ])
    expect([ child.localAtendimento, child.sexo, child.turno, child.gestante, child.necessidadesEspeciais ]).to eq([ 1, 1, 2, false, true ])
    expect([ child.dtNascimento, child.dataHoraInicialAtendimento, child.dataHoraFinalAtendimento ])
      .to eq([ ms(Date.new(1980, 5, 10).in_time_zone), ms(started), ms(started + 30.minutes) ])
    expect([ child.cpfCidadao, child.cnsCidadao, child.stCidadaoNaoPossuiCpf, child.justificativaCidadaoNaoPossuiCpf ])
      .to eq([ "52998224725", nil, false, nil ])
    expect(child.exame.map { |e| [ e.codigoExame, e.solicitadoAvaliado ] }).to eq([ [ "0204010179", [ "S" ] ] ])
    expect(child.medicoes.pressaoArterialSistolica).to eq(120)
    expect(child.problemasCondicoes.map { |p| [ p.uuidProblema, p.ciap, p.cid10, p.isAvaliado ] })
      .to eq([ [ "p-1", "D82", nil, true ], [ "p-2", nil, "K021", true ] ])
    expect([ child.medicamentos, child.encaminhamentos, child.numProntuario ]).to eq([ nil, nil, nil ])
    expect { master.validate }.not_to raise_error
    expect(Ledi::Version.deserialize(master.class, Ledi::Version.serialize(master))).to eq(master)
  end

  it "sexo masculino: gestante omitido; feminino sem gestação: false" do
    male = described_class.new(identity: identity.with(sex: "male"), care: care.with(pregnant: nil), source_id: SecureRandom.uuid)
    expect([ child_of(male).gestante, child_of(male).sexo ]).to eq([ nil, 0 ])
    expect(child_of(ficha).gestante).to be(false)
    pregnant = described_class.new(identity: identity, care: care.with(pregnant: true), source_id: SecureRandom.uuid)
    expect(child_of(pregnant).gestante).to be(true)
  end

  it "paciente sem CPF: CNS com stCidadaoNaoPossuiCpf e a justificativa; nunca CPF e CNS juntos" do
    no_cpf = identity.with(citizen_cpf: nil, citizen_cns: "700000000000013", citizen_no_cpf_reason: 3)
    master = described_class.new(identity: no_cpf, care: care, source_id: SecureRandom.uuid).to_thrift(uuid: "1234567-s")
    child = master.atendimentosOdontologicos.sole
    expect([ child.cpfCidadao, child.cnsCidadao, child.stCidadaoNaoPossuiCpf, child.justificativaCidadaoNaoPossuiCpf ])
      .to eq([ nil, "700000000000013", true, 3 ])
    expect { master.validate }.not_to raise_error
    [ child, child_of(ficha) ].each { |c| expect([ c.cpfCidadao, c.cnsCidadao ].compact.size).to eq(1) }
  end

  it "sem tipo de consulta, procedimento, fornecimento, exame nem medição: os campos ficam fora" do
    bare = care.with(care_type: 4, consultation_type: nil, supplies: [], procedures: [], exams: [], measurements: nil)
    child = child_of(described_class.new(identity: identity, care: bare, source_id: SecureRandom.uuid))
    expect([ child.tiposConsultaOdonto, child.procedimentosRealizados, child.tiposFornecimOdonto, child.exame, child.medicoes ])
      .to eq([ nil, nil, nil, nil, nil ])
    expect(child.tipoAtendimento).to eq(4)
  end

  # Desvio 9: o dentista leva o CID-10; o TSB/ASB só o CIAP-2 (o prontuário não muda).
  it "auxiliar de saúde bucal: o problema em CID-10 fica fora, o CIAP-2 vai" do
    asb = described_class.new(identity: identity.with(cbo: "322430"), care: care, source_id: SecureRandom.uuid)
    expect(child_of(asb).problemasCondicoes.map { |p| [ p.uuidProblema, p.ciap, p.cid10 ] }).to eq([ [ "p-1", "D82", nil ] ])
  end

  it "CEO sem equipe: INE nulo no cabeçalho, a interface aceita" do
    ceo = described_class.new(identity: identity.with(ine: nil, cbo: "223212"), care: care, source_id: SecureRandom.uuid)
    expect { Ledi::Ficha.assert!(ceo) }.not_to raise_error
    master = ceo.to_thrift(uuid: "1234567-ceo")
    expect(master.headerTransport.lotacaoFormPrincipal.ine).to be_nil
    expect(master.atendimentosOdontologicos.sole.localAtendimento).to eq(1)
    expect { master.validate }.not_to raise_error
  end

  it "o início do problema nunca fica antes do nascimento" do
    young = identity.with(birth_date: Date.new(2000, 6, 15))
    early = care.with(problems: [ problems.first.with(onset_on: Date.new(2000, 6, 1)) ])
    sent = child_of(described_class.new(identity: young, care: early, source_id: SecureRandom.uuid)).problemasCondicoes.sole
    expect(sent.dataInicioProblema).to eq(ms(Date.new(2000, 6, 15).in_time_zone))
  end
end
