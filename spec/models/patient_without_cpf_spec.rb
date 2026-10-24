require "rails_helper"
require "rake"

# Módulo 24a (ADR 0042): paciente digitado sem CPF — justificativa da ficha,
# CNS opcional e único, chave cega de duplicados; o CPF chega depois.
RSpec.describe "Paciente sem CPF" do
  before { clinical_city! }

  let(:by) { verifier! }

  def typed(**over)
    Patients::CreateTyped.call(attrs: { "full_name" => "Joao Pedro Silva", "birth_date" => "1990-02-03", "sex" => "male",
                                        "no_cpf_reason" => "8" }.merge(over.transform_keys(&:to_s)), by: by)
  end

  it "grava sem CPF com a justificativa, nome sem espaços sobrando, chave cega e evento só com ids" do
    result = typed(full_name: "  Joao   Pedro  Silva ", cns: valid_cns(1))
    expect(result).to be_ok
    patient = result.payload[:patient].reload
    expect(patient.cpf).to be_nil
    expect(patient.cpf_masked).to be_nil
    expect(patient.full_name).to eq("Joao Pedro Silva")
    expect(patient.cns).to eq(valid_cns(1))
    expect(patient.match_key).to eq(Patients::MatchKey.for("Joao Pedro Silva", "1990-02-03"))
    event = DomainEvent.where(name: "patient.created").last
    expect(event.payload).to eq("patient_id" => patient.id, "user_id" => by.id)
    expect(patient.inspect).not_to include(valid_cns(1))
    expect(patient.inspect).not_to include("Pedro")
  end

  it "sem CPF e sem justificativa → cpf_or_reason_required" do
    expect(typed(no_cpf_reason: nil).reason).to eq(:cpf_or_reason_required)
    expect(Patient.count).to eq(0)
  end

  it "justificativa fora da lista → invalid_patient com o caminho" do
    result = typed(no_cpf_reason: "1")
    expect(result.reason).to eq(:invalid_patient)
    expect(result.details).to eq(path: "new_patient.no_cpf_reason")
  end

  it "recusa nome, nascimento e sexo inválidos pelo caminho, sem o valor" do
    { full_name: "Jo", birth_date: "1990-02-30", sex: "x", mother_name: "Maria 3" }.each do |field, value|
      result = typed(field => value)
      expect(result.reason).to eq(:invalid_patient), field.to_s
      expect(result.details).to eq(path: "new_patient.#{field}")
    end
    expect(typed(birth_date: (Time.zone.today + 1).iso8601).details).to eq(path: "new_patient.birth_date")
  end

  it "nome e nome da mãe pela regra Validar nome do LEDI (Dictionary.valid_name?)" do
    { full_name: "Joaquim", mother_name: "A A da Silva" }.each do |field, value|
      expect(typed(field => value).details).to eq(path: "new_patient.#{field}"), field.to_s
    end
    expect(typed(full_name: "Li Wu").details).to eq(path: "new_patient.full_name")
    expect(typed(full_name: "João D’Ávila Gonçalves", mother_name: "Maria da Paz")).to be_ok
  end

  it "CNS com dígito inválido → invalid_cns" do
    cns = valid_cns(2)
    wrong = cns[0..13] + ((cns[14].to_i + 1) % 10).to_s
    expect(typed(cns: wrong).reason).to eq(:invalid_cns)
  end

  it "dois pacientes com o mesmo CNS → o segundo cns_taken" do
    expect(typed(cns: valid_cns(3))).to be_ok
    expect(typed(cns: valid_cns(3), full_name: "Ana Maria Souza").reason).to eq(:cns_taken)
  end

  it "o índice único é a última palavra do CNS (corrida) → cns_taken" do
    expect(typed(cns: valid_cns(4))).to be_ok
    allow(Patient).to receive(:exists?).and_wrap_original do |original, *args, **kw|
      conditions = args.first || kw
      conditions.is_a?(Hash) && conditions.key?(:cns) ? false : original.call(*args, **kw)
    end
    expect(typed(cns: valid_cns(4), full_name: "Ana Maria Souza").reason).to eq(:cns_taken)
    expect(Patient.count).to eq(1)
  end

  it "dentro da transação de quem chama, a corrida do CNS vira cns_taken e a transação segue usável" do
    expect(typed(cns: valid_cns(5))).to be_ok
    allow(Patient).to receive(:exists?).and_wrap_original do |original, *args, **kw|
      conditions = args.first || kw
      conditions.is_a?(Hash) && conditions.key?(:cns) ? false : original.call(*args, **kw)
    end
    ApplicationRecord.transaction do
      expect(typed(cns: valid_cns(5), full_name: "Ana Maria Souza").reason).to eq(:cns_taken)
      expect(Patient.count).to eq(1)
    end
  end

  it "com CPF delega ao AddCpf: grava o CPF, sem justificativa, e liga o par validado" do
    citizen = verified_citizen!(9, full_name: "João Pedro da Silva", sex: "male")
    result = typed(no_cpf_reason: nil, cpf: citizen.cpf)
    expect(result).to be_ok
    patient = result.payload[:patient].reload
    expect(patient.cpf).to eq(citizen.cpf)
    expect(patient.no_cpf_reason).to be_nil
    expect(citizen.reload.patient_id).to eq(patient.id)
    expect(patient.full_name).to eq("João Pedro da Silva")
  end

  it "com CPF de outro paciente → cpf_taken, nada gravado; com CPF e justificativa → invalid_patient" do
    other, _citizen = exam_patient!(10, age: 40, sex: "male")
    expect(typed(no_cpf_reason: nil, cpf: other.cpf).reason).to eq(:cpf_taken)
    expect(typed(no_cpf_reason: nil, cpf: "123").reason).to eq(:invalid_cpf)
    expect(typed(cpf: valid_cpf(11)).details).to eq(path: "new_patient.no_cpf_reason")
    expect(Patient.count).to eq(1)
  end

  it "Pairs.of: pares validados e não excluídos do paciente, e os do CPF quando ele tem" do
    patient, citizen = exam_patient!(12, age: 40, sex: "male")
    expect(Patients::Pairs.of(patient)).to eq([ citizen ])
    sem_cpf = typed.payload[:patient]
    expect(Patients::Pairs.of(sem_cpf)).to be_empty
  end

  describe "rake patients:backfill_match_keys" do
    before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("patients:backfill_match_keys") }
    before { Rake::Task["patients:backfill_match_keys"].reenable }

    def invoke
      original, $stdout = $stdout, StringIO.new
      Rake::Task["patients:backfill_match_keys"].invoke
      $stdout.string
    ensure
      $stdout = original
    end

    it "preenche a chave de paciente antigo, é idempotente e imprime só contagens" do
      patient = typed.payload[:patient]
      patient.update_columns(match_key: nil)
      expect(patient.reload.match_key).to be_nil

      out = invoke
      expect(patient.reload.match_key).to eq(Patients::MatchKey.for("Joao Pedro Silva", "1990-02-03"))
      expect(out).to include("1 preenchidas")
      expect(out).not_to match(/joao|1990/i)

      Rake::Task["patients:backfill_match_keys"].reenable
      expect(invoke).to include("0 preenchidas")
    end

    # Chave gravada pela regra antiga (hífen e apóstrofo apagados) é regravada.
    it "regrava a chave antiga de quem tem hífen ou apóstrofo no nome" do
      patient = typed(full_name: "Joao D'Avila Silva").payload[:patient]
      patient.update_columns(match_key: "joao davila silva|1990-02-03")

      out = invoke
      expect(patient.reload.match_key).to eq("joao d avila silva|1990-02-03")
      expect(out).to include("1 preenchidas")
    end
  end
end
