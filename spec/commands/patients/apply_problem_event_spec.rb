# spec/commands/patients/apply_problem_event_spec.rb
require "rails_helper"

# ADR 0031 (spec §3, §8): a lista muda só por evento ligado a consulta ou
# adendo; os eventos reconstroem o estado; sem dois ativos iguais; incluir o
# que foi resolvido reativa a mesma linha.
RSpec.describe Patients::ApplyProblemEvent do
  before { Current.city = TEST_CITY_A; ciap2_release!; cid10_release! }
  after { Current.reset }

  let(:doctor) { User.create!(email_address: "medica-#{SecureRandom.hex(3)}@cidade.gov.br", password: "senha-segura-123") }
  let(:patient) { Patient.create!(cpf: verified_citizen!(1).cpf) }
  let(:consultation) { Struct.new(:id).new(SecureRandom.uuid) }
  let(:ciap_release) { TerminologyRelease.active.find_by!(kind: "ciap2").id }

  def apply(action, **args)
    described_class.call(patient: patient, action: action, by: doctor, source: { consultation: consultation }, **args)
  end

  def add(code = "T90", **args) = apply("add", terminology: "ciap2", code: code, release_id: ciap_release, **args)

  it "inclui: problema ativo com início e precisão; evento com a consulta; trilha só com ids" do
    result = add(onset_on: Date.new(2025, 8, 1), onset_precision: "month")
    problem = result.payload[:problem]
    expect(problem).to have_attributes(status: "active", code: "T90", onset_on: Date.new(2025, 8, 1), onset_precision: "month")
    expect(result.payload[:event]).to have_attributes(kind: "added", consultation_id: consultation.id, user_id: doctor.id)
    expect(DomainEvent.where(name: "patient_problem.changed").sole.payload)
      .to eq("patient_problem_id" => problem.id, "kind" => "added", "consultation_id" => consultation.id)
  end

  it "incluir de novo o ativo é avaliar (sem evento); resolver; incluir o resolvido reativa a mesma linha" do
    problem = add.payload[:problem]
    again = add
    expect([ again.payload[:problem].id, again.payload[:event] ]).to eq([ problem.id, nil ])
    resolved = apply("resolve", problem: problem, on: Date.new(2026, 10, 7))
    expect(resolved.payload[:problem]).to have_attributes(status: "resolved", resolved_on: Date.new(2026, 10, 7))
    reactivated = add
    expect(reactivated.payload[:problem].id).to eq(problem.id)
    expect(reactivated.payload[:event].kind).to eq("reactivated")
    expect(problem.reload).to have_attributes(status: "active", resolved_on: nil)
    expect(PatientProblem.where(patient: patient).count).to eq(1)
  end

  it "os eventos reconstroem o estado" do
    problem = add(onset_on: Date.new(2020, 1, 1), onset_precision: "year").payload[:problem]
    apply("correct_onset", problem: problem, onset_on: Date.new(2019, 3, 1), onset_precision: "month")
    apply("resolve", problem: problem, on: Date.new(2026, 1, 2))
    add
    problem.reload
    expect(Patients::ProblemReplay.state(problem))
      .to eq(status: problem.status, onset_on: problem.onset_on, onset_precision: problem.onset_precision,
             resolved_on: problem.resolved_on)
    expect(Patients::ProblemReplay.history(problem).map { |e| e[:kind] }).to eq(%w[added onset_corrected resolved reactivated])
  end

  it "CID-10 convive com a CIAP-2 do mesmo problema clínico (terminologias diferentes)" do
    add("T90")
    cid = apply("add", terminology: "cid10", code: "E119", release_id: TerminologyRelease.active.find_by!(kind: "cid10").id)
    expect(cid).to be_ok
    expect(PatientProblem.where(patient: patient).pluck(:terminology).sort).to eq(%w[ciap2 cid10])
  end

  it "recusas: avaliar sem problema, resolver o resolvido, problema de outro paciente, ação desconhecida" do
    problem = add.payload[:problem]
    apply("resolve", problem: problem)
    other = Patient.create!(cpf: verified_citizen!(2).cpf)
    foreign = described_class.call(patient: other, action: "add", by: doctor, source: { consultation: consultation },
                                   terminology: "ciap2", code: "K86", release_id: ciap_release).payload[:problem]
    expect(apply("evaluate").reason).to eq(:invalid_problem)
    expect(apply("resolve", problem: problem.reload).reason).to eq(:invalid_problem)
    expect(apply("evaluate", problem: foreign).reason).to eq(:invalid_problem)
    expect(apply("apagar", problem: problem).reason).to eq(:invalid_problem)
    expect { described_class.call(patient: patient, action: "add", by: doctor, source: {}) }.to raise_error(ArgumentError)
  end
end
