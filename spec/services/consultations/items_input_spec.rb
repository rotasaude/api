# spec/services/consultations/items_input_spec.rb
require "rails_helper"

# ADR 0031 (spec §4; Task 1): o corpo do autosave e do adendo → colunas e
# itens normalizados. Review Focus 3: entrada nas bordas vira 422 com
# field/index, nunca 500 nem dado parcial.
RSpec.describe Consultations::ItemsInput do
  before { Current.city = TEST_CITY_A; ciap2_release!; cid10_release!; sigtap_release! }
  after { Current.reset }

  let(:citizen) { verified_citizen!(1, age: 46, sex: "female") }
  let(:patient) { Patient.create!(cpf: citizen.cpf, birth_date: citizen.birth_date, sex: "female") }
  let(:today) { Time.zone.today }

  # Hash sem chaves entre chaves (input("a" => 1)) chega como kwargs de chave string.
  def input(params = {}, cbo: "225125", **string_keys)
    described_class.call(params.merge(string_keys), patient: patient, cbo: cbo, on: today)
  end

  def failure(params = {}, cbo: "225125", **string_keys)
    result = input(params, cbo: cbo, **string_keys)
    [ result.reason, result.details[:field] || result.details[:index] ]
  end

  it "só as chaves presentes; texto preservado, vazio vira nil; sinais substituem; itens normalizados" do
    result = input("subjective" => "  dor\r\nlombar ", "plan" => "", "vitals" => { "systolic" => "130", "diastolic" => 85 },
                   "care_type" => 5, "conducts" => [ 1, 9 ],
                   "evaluated_problems" => [ { "terminology" => "cid10", "code" => "e11.9", "action" => "add",
                                               "onset_on" => "2025-08-17", "onset_precision" => "month" } ],
                   "exam_requests" => [ { "sigtap_code" => "0202010503", "cid10_justification" => "E119" } ],
                   "desconhecida" => 1)
    expect(result).to be_ok
    attrs = result.payload[:attrs]
    expect(attrs.slice("subjective", "plan", "care_type", "systolic", "diastolic", "spo2"))
      .to eq("subjective" => "  dor\r\nlombar ", "plan" => nil, "care_type" => 5, "systolic" => 130, "diastolic" => 85, "spo2" => nil)
    expect(attrs).not_to have_key("objective")
    expect(result.payload[:draft_items]).to eq(
      "conducts" => [ 1, 9 ],
      "evaluated_problems" => [ { "problem_id" => nil, "terminology" => "cid10", "code" => "E119",
                                  "release_id" => TerminologyRelease.active.find_by!(kind: "cid10").id, "action" => "add",
                                  "onset_on" => "2025-08-01", "onset_precision" => "month" } ],
      "exam_requests" => [ { "sigtap_code" => "0202010503", "sigtap_competence" => today.strftime("%Y%m"),
                             "cid10_justification" => "E119" } ]
    )
  end

  # Contrato §4: códigos chegam como string de dígitos (o dashboard manda "5",
  # ["9"]); inteiro segue aceito. Guarda inteiro (coluna e ficha LEDI).
  it "care_type e conducts: string de dígitos vira inteiro; inteiro segue aceito" do
    result = input("care_type" => "5", "conducts" => [ "9", 1 ])
    expect(result).to be_ok
    expect(result.payload[:attrs]["care_type"]).to eq(5)
    expect(result.payload[:draft_items]["conducts"]).to eq([ 9, 1 ])
    expect(input("care_type" => nil).payload[:attrs]).to eq("care_type" => nil)
  end

  it "avaliar e resolver usam o problema do paciente" do
    problem = ApplicationRecord.transaction do
      Patients::ApplyProblemEvent.call(patient: patient, action: "add", by: verifier!, source: { consultation: Struct.new(:id).new(SecureRandom.uuid) },
                                       terminology: "ciap2", code: "T90", release_id: TerminologyRelease.active.find_by!(kind: "ciap2").id)
                                 .payload[:problem]
    end
    result = input("evaluated_problems" => [ { "problem_id" => problem.id, "action" => "resolve" } ])
    expect(result.payload[:draft_items]["evaluated_problems"].sole)
      .to include("problem_id" => problem.id, "terminology" => "ciap2", "code" => "T90", "action" => "resolve")
    other = Patient.create!(cpf: verified_citizen!(2).cpf)
    expect(described_class.call({ "evaluated_problems" => [ { "problem_id" => problem.id, "action" => "evaluate" } ] },
                                patient: other, cbo: "225125", on: today).reason).to eq(:invalid_problem)
  end

  {
    { "subjective" => "x" * 20_001 } => [ :text_too_long, "subjective" ],
    { "plan" => [ "a" ] } => [ :invalid_text, "plan" ],
    { "vitals" => { "systolic" => 130 } } => [ :implausible_vital, "diastolic" ],
    { "vitals" => { "diastolic" => 80 } } => [ :implausible_vital, "systolic" ],
    { "vitals" => { "spo2" => "37,5" } } => [ :implausible_vital, "spo2" ],
    { "vitals" => "lixo" } => [ :implausible_vital, "vitals" ],
    { "care_type" => 4 } => [ :invalid_care_type, nil ],
    { "care_type" => "abc" } => [ :invalid_care_type, nil ],
    { "care_type" => "5.0" } => [ :invalid_care_type, nil ],
    { "care_type" => "" } => [ :invalid_care_type, nil ],
    { "care_type" => "4" } => [ :invalid_care_type, nil ],
    { "care_type" => 5.0 } => [ :invalid_care_type, nil ],
    { "conducts" => [ 3 ] } => [ :invalid_conduct, nil ],
    { "conducts" => [ 1, 1 ] } => [ :invalid_conduct, nil ],
    { "conducts" => (1..13).to_a } => [ :invalid_conduct, nil ],
    { "conducts" => "9" } => [ :invalid_conduct, nil ],
    { "conducts" => [ "abc" ] } => [ :invalid_conduct, nil ],
    { "conducts" => [ "9.0" ] } => [ :invalid_conduct, nil ],
    { "conducts" => [ "" ] } => [ :invalid_conduct, nil ],
    { "conducts" => [ "3" ] } => [ :invalid_conduct, nil ],
    { "conducts" => [ 1, "1" ] } => [ :invalid_conduct, nil ],
    { "evaluated_problems" => "T90" } => [ :invalid_problem, nil ],
    { "evaluated_problems" => [ "T90" ] } => [ :invalid_problem, 0 ],
    { "evaluated_problems" => [ { "terminology" => "ciap2", "code" => "Z99", "action" => "add" } ] } => [ :invalid_problem, 0 ],
    { "evaluated_problems" => [ { "terminology" => "ciap2", "code" => "T90", "action" => "add" },
                                { "terminology" => "ciap2", "code" => "t90", "action" => "add" } ] } => [ :invalid_problem, 1 ],
    { "evaluated_problems" => [ { "action" => "evaluate", "problem_id" => "nao-e-uuid" } ] } => [ :invalid_problem, 0 ],
    { "evaluated_problems" => [ { "terminology" => "ciap2", "code" => "T90", "action" => "add", "onset_on" => "2999-01-01",
                                  "onset_precision" => "day" } ] } => [ :invalid_onset, 0 ],
    { "evaluated_problems" => [ { "terminology" => "ciap2", "code" => "T90", "action" => "add", "onset_on" => "1900-01-01",
                                  "onset_precision" => "year" } ] } => [ :invalid_onset, 0 ],
    { "evaluated_problems" => [ { "terminology" => "ciap2", "code" => "T90", "action" => "add", "onset_on" => "2025-02-30",
                                  "onset_precision" => "day" } ] } => [ :invalid_onset, 0 ],
    { "evaluated_problems" => [ { "terminology" => "ciap2", "code" => "T90", "action" => "add", "onset_on" => "2025-02-01" } ] } =>
      [ :invalid_onset, 0 ],
    { "evaluated_problems" => [ { "terminology" => "cid10", "code" => "C61", "action" => "add" } ] } => [ :cid10_sex_incompatible, 0 ],
    { "exam_requests" => [ { "sigtap_code" => "0301010064" } ] } => [ :invalid_exam, 0 ],
    { "exam_requests" => [ { "sigtap_code" => "0202010503" }, { "sigtap_code" => "0202010503" } ] } => [ :invalid_exam, 1 ],
    { "exam_requests" => [ { "sigtap_code" => "0202010503", "cid10_justification" => "Z999" } ] } => [ :invalid_exam, 0 ],
    { "exam_requests" => Array.new(101) { { "sigtap_code" => "0202010503" } } } => [ :invalid_exam, nil ]
  }.each do |params, expected|
    it("#{params.inspect.truncate(90)} → #{expected.inspect}") { expect(failure(params)).to eq(expected) }
  end

  it "CID-10 recusado ao CBO quando a regra restringe" do
    allow(Ledi::ConsultationMapping).to receive(:cid10_allowed?).and_return(false)
    expect(failure("evaluated_problems" => [ { "terminology" => "cid10", "code" => "E119", "action" => "add" } ]))
      .to eq([ :cid10_not_allowed_for_cbo, 0 ])
    expect(failure("exam_requests" => [ { "sigtap_code" => "0202010503", "cid10_justification" => "E119" } ]))
      .to eq([ :cid10_not_allowed_for_cbo, 0 ])
  end

  # Regra real (physicians_only), sem stub: médico 225xxx pode CID-10; enfermeiro só CIAP-2.
  describe "CID-10 por CBO (regra real)" do
    let(:cid_problem) { { "evaluated_problems" => [ { "terminology" => "cid10", "code" => "E119", "action" => "add" } ] } }
    let(:ciap_problem) { { "evaluated_problems" => [ { "terminology" => "ciap2", "code" => "T90", "action" => "add" } ] } }
    let(:cid_exam) { { "exam_requests" => [ { "sigtap_code" => "0202010503", "cid10_justification" => "E119" } ] } }

    it "enfermeiro (223505) com problema CID-10 é recusado, com o índice" do
      expect(failure(cid_problem, cbo: "223505")).to eq([ :cid10_not_allowed_for_cbo, 0 ])
    end

    it "enfermeiro com CIAP-2 segue" do
      expect(input(ciap_problem, cbo: "223505")).to be_ok
    end

    it "médico (225125) com CID-10 segue" do
      expect(input(cid_problem, cbo: "225125")).to be_ok
    end

    it "justificativa CID-10 no exame: enfermeiro recusado com o índice, médico segue" do
      expect(failure(cid_exam, cbo: "223505")).to eq([ :cid10_not_allowed_for_cbo, 0 ])
      expect(input(cid_exam, cbo: "225125")).to be_ok
    end
  end

  describe "início do problema contra o nascimento (2000-06-15)" do
    let(:patient) { Patient.create!(cpf: citizen.cpf, birth_date: "2000-06-15", sex: "female") }

    def onset(date, precision)
      input("evaluated_problems" => [ { "terminology" => "ciap2", "code" => "T90", "action" => "add",
                                         "onset_on" => date, "onset_precision" => precision } ]).reason
    end

    it "mês: anterior ao nascimento falha; o mês do nascimento passa" do
      expect(onset("2000-02-01", "month")).to eq(:invalid_onset)
      expect(onset("2000-05-01", "month")).to eq(:invalid_onset)
      expect(onset("2000-06-01", "month")).to be_nil
    end

    it "ano: o ano do nascimento passa; o anterior falha" do
      expect(onset("2000-01-01", "year")).to be_nil
      expect(onset("1999-01-01", "year")).to eq(:invalid_onset)
    end

    it "dia: antes do nascimento falha; no dia passa" do
      expect(onset("2000-06-14", "day")).to eq(:invalid_onset)
      expect(onset("2000-06-15", "day")).to be_nil
    end
  end

  it "sexo: masculino com C61 passa" do
    male = Patient.create!(cpf: verified_citizen!(3).cpf, birth_date: "1970-01-01", sex: "male")
    result = described_class.call({ "evaluated_problems" => [ { "terminology" => "cid10", "code" => "C61", "action" => "add" } ] },
                                  patient: male, cbo: "225125", on: today)
    expect(result).to be_ok
  end

  it "exam_requests que não é lista falha como invalid_exam" do
    expect(failure("exam_requests" => "x")).to eq([ :invalid_exam, nil ])
  end
end
