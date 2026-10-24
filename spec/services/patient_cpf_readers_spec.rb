require "rails_helper"

# Inventário do plano 24a: cada leitor de patients.cpf com um paciente sem CPF.
# Os leitores que exigem consulta (ficha da consulta, impresso) e o fechamento
# do faturamento estão nos specs do próprio módulo (consultation_ficha_spec,
# print_spec, close_spec); as formas JSON, em clinical_record_spec.
RSpec.describe "Leitores de patients.cpf com paciente sem CPF" do
  before { clinical_city! }

  let(:no_cpf) do
    Patients::CreateTyped.call(attrs: { "full_name" => "Lia Santos", "birth_date" => "2026-08-01", "sex" => "female",
                                        "no_cpf_reason" => "3", "cns" => valid_cns(31) }, by: verifier!).payload[:patient]
  end

  it "Patients::Pairs.of nunca casa por cpf nulo" do
    verified_citizen!(1) # um par qualquer
    expect(Patients::Pairs.of(no_cpf)).to be_empty
  end

  it "ficha de atendimento individual: CNS no lugar do CPF, nunca os dois" do
    identity = ledi_identity(citizen_cpf: nil, citizen_cns: no_cpf.cns)
    thrift = Ledi::Fichas::IndividualCare.new(identity: identity, care: ledi_care, source_id: SecureRandom.uuid).to_thrift(uuid: "1234567-#{SecureRandom.uuid}")
    child = thrift.atendimentosIndividuais.first
    # O campo do CNS no FichaAtendimentoIndividualChildThrift é `cns` (id 2 do IDL 8.7.0).
    expect([ child.cpfCidadao, child.cns, child.stCidadaoNaoPossuiCpf ]).to eq([ nil, no_cpf.cns, true ])
    with_cpf = Ledi::Fichas::IndividualCare.new(identity: ledi_identity(citizen_cpf: "52998224725", citizen_cns: nil), care: ledi_care,
                                                source_id: SecureRandom.uuid).to_thrift(uuid: "1234567-x").atendimentosIndividuais.first
    expect([ with_cpf.cpfCidadao, with_cpf.cns, with_cpf.stCidadaoNaoPossuiCpf ]).to eq([ "52998224725", nil, false ])
  end

  it "BPA-I: crítica só sem CPF e sem CNS; linha 03 com CNS em 60–74, CPF em brancos e prd_sem_cpf S" do
    line = bpa_i_line(cpf: nil, cns: no_cpf.cns)
    row = Billing::BpaFile.build(header: bpa_header, c_lines: [], i_lines: [ line ]).bytes.lines.find { |l| l.start_with?("03") }
    expect(row[59, 15]).to eq(no_cpf.cns)
    expect(row[338, 11]).to eq(" " * 11)
    expect(row[349]).to eq(" ") # prd_situacao_rua (350) segue em branco (L18)
    expect(row[350]).to eq("S")
    expect(Billing::Critic.patient_identifier_missing?(no_cpf)).to be(false)
    no_cpf.update_columns(cns: nil)
    expect(Billing::Critic.patient_identifier_missing?(no_cpf.reload)).to be(true)
    expect(Billing::Critic.patient_identifier_missing?(nil)).to be(true)
    # Sem os dois a linha não nasce (nunca CPF inventado nem linha sem paciente).
    expect { Billing::BpaFile.build(header: bpa_header, c_lines: [], i_lines: [ bpa_i_line(cpf: nil, cns: nil) ]) }
      .to raise_error(ArgumentError, /15 posições/)
  end

  it "BPA-I com CPF: CNS do paciente em brancos (nunca os dois), CPF em 339–349, prd_sem_cpf N" do
    row = Billing::BpaFile.build(header: bpa_header, c_lines: [], i_lines: [ bpa_i_line(cpf: "52998224725", cns: valid_cns(32)) ])
                          .bytes.lines.find { |l| l.start_with?("03") }
    expect([ row[59, 15], row[338, 11], row[349], row[350] ]).to eq([ " " * 15, "52998224725", " ", "N" ])
  end

  it "FHIR do exame: CNS do paciente sem CPF; sem os dois, nil" do
    expect(Exams::Fhir::Identifiers.for_patient(no_cpf)).to eq(system: Exams::Fhir::Identifiers::CNS_SYSTEM, value: no_cpf.cns)
    cns = Exams::Fhir::Identifiers::CNS_SYSTEM
    cpf = Exams::Fhir::Identifiers::CPF_SYSTEM
    expect(Exams::Fhir::Identifiers.matches?(no_cpf, "system" => cns, "value" => no_cpf.cns)).to be(true)
    expect(Exams::Fhir::Identifiers.matches?(no_cpf, "system" => cns, "value" => valid_cns(33))).to be(false)
    expect(Exams::Fhir::Identifiers.matches?(no_cpf, "system" => cpf, "value" => "52998224725")).to be(false)
    no_cpf.update_columns(cns: nil)
    expect(Exams::Fhir::Identifiers.for_patient(no_cpf.reload)).to be_nil
  end

  it "linha do tempo, inscrição em linha de cuidado e acesso ao prontuário não quebram com cpf nulo" do
    verified_citizen!(2) # um par qualquer, com CPF
    expect(Timeline::Person.for_patient(no_cpf).citizen_ids).to eq([])
    unit = create_unit
    grant = ClinicalRecord::Access.call(user: doctor!(unit), patient: no_cpf)
    expect([ grant.kind, grant.reason ]).to eq([ :denied, :out_of_context ])
    expect(no_cpf.cpf.to_s[-3, 3]).to be_nil # Exams::Json#cpf_last3 (inventário #15)
  end

  it "documento clínico sem CPF continua recusado (inalcançável hoje: exige consulta)" do
    result = ClinicalDocuments::Content::PatientIdentification.call({ "address" => {} }, required: true, patient: no_cpf)
    expect(result).to be_failure
    expect([ result.reason, result.details ]).to eq([ :patient_identification_required, { field: "patient_identification.cpf" } ])
  end

  it "paciente: has_cpf e cns_masked (só os 4 últimos) nas formas que o mostram (L8)" do
    expect(no_cpf.cns_masked).to eq("*** **** **** #{no_cpf.cns[-4..]}")
    expect(ClinicalRecord::Json.patient_block(no_cpf, nil))
      .to include(cpf_masked: nil, has_cpf: false, cns_masked: no_cpf.cns_masked)
    citizen = verified_citizen!(3)
    expect(ClinicalRecord::Json.patient_block(nil, citizen)).to include(cpf_masked: citizen.cpf_masked, has_cpf: true)
  end
end
