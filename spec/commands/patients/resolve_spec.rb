require "rails_helper"

# ADR 0031 (spec §3): o paciente nasce na primeira consulta de um par
# VALIDADO; os pares validados do CPF se ligam a ele; o perfil segue o par
# validado mais recente; divergência de nascimento/sexo fica registrada.
RSpec.describe Patients::Resolve do
  include ActiveSupport::Testing::TimeHelpers
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:citizen) { verified_citizen!(1, full_name: "Maria Aparecida da Silva", social_name: "Mariana") }

  def second_pair(of, phone:, **profile)
    other = Citizen.create!({ cpf: of.cpf, phone: phone, birth_date: of.birth_date, sex: of.sex, profile_source: "verified" }.merge(profile))
    CitizenVerification.create!(citizen: other, verified_by_user: verifier!, verified_at: Time.current)
    other.update!(verification_level: "verified", full_name: "Maria A. da Silva")
    other
  end

  it "cria o paciente do CPF com nome, nascimento e sexo do par; liga o par; evento só com ids" do
    result = described_class.call(citizen)
    expect(result).to be_ok
    patient = result.payload[:patient]
    expect(result.payload[:created]).to be(true)
    expect(patient.slice(:cpf, :full_name, :social_name, :mother_name, :birth_date, :sex))
      .to eq("cpf" => citizen.cpf, "full_name" => "Maria Aparecida da Silva", "social_name" => "Mariana",
             "mother_name" => "Joana da Silva", "birth_date" => citizen.birth_date, "sex" => "female")
    expect(citizen.reload.patient_id).to eq(patient.id)
    expect(DomainEvent.where(name: "patient.created").sole.payload).to eq("patient_id" => patient.id, "citizen_id" => citizen.id)
  end

  it "de novo: o mesmo paciente, sem evento novo" do
    first = described_class.call(citizen).payload[:patient]
    again = described_class.call(citizen.reload)
    expect([ again.payload[:patient].id, again.payload[:created] ]).to eq([ first.id, false ])
    expect(DomainEvent.where(name: %w[patient.created patient.linked]).count).to eq(1)
  end

  it "par declarado nunca é ligado nem cria paciente" do
    declared = screening_citizen!(2)
    expect(described_class.call(declared).reason).to eq(:citizen_not_verified)
    expect([ Patient.count, declared.reload.patient_id ]).to eq([ 0, nil ])
  end

  it "segundo par validado do CPF liga ao mesmo paciente; o perfil segue o mais recente; divergência uma vez" do
    patient = described_class.call(citizen).payload[:patient]
    other = travel_to(1.minute.from_now) { second_pair(citizen, phone: "+5541990000099", sex: "male") }
    result = described_class.call(other)
    expect(result.payload[:patient].id).to eq(patient.id)
    expect(DomainEvent.where(name: "patient.linked").sole.payload).to eq("patient_id" => patient.id, "citizen_id" => other.id)
    expect(patient.reload.sex).to eq("male")
    expect(PatientProfileDivergence.sole).to have_attributes(patient_id: patient.id, citizen_id: citizen.id, fields: %w[sex])
    described_class.call(other.reload)
    expect(PatientProfileDivergence.count).to eq(1)
  end

  it "o nome vem do par validado mais recente que TEM nome (par antigo sem nome não apaga)" do
    patient = described_class.call(citizen).payload[:patient]
    other = travel_to(1.minute.from_now) { second_pair(citizen, phone: "+5541990000098") }
    other.update_columns(full_name: nil)
    described_class.call(other.reload)
    expect(patient.reload.full_name).to eq("Maria Aparecida da Silva")
  end

  it "revogar a validação não desliga; consulta nova pede validar de novo" do
    described_class.call(citizen)
    citizen.active_verification.update!(revoked_at: Time.current, revoke_reason: "documento rasurado",
                                        revoked_by_user: staff_with("adm-#{SecureRandom.hex(3)}@x.gov.br", "municipal_admin"))
    citizen.update!(verification_level: "declared")
    expect(citizen.reload.patient_id).to be_present
    expect(described_class.call(citizen).reason).to eq(:citizen_not_verified)
  end

  it "completar nomes de par ligado atualiza o paciente" do
    patient = described_class.call(citizen).payload[:patient]
    Citizens::CompleteNames.call(verification: citizen.active_verification, full_name: "Maria Aparecida Souza",
                                 social_name: nil, mother_name: nil, by: verifier!)
    expect(patient.reload.slice(:full_name, :social_name)).to eq("full_name" => "Maria Aparecida Souza", "social_name" => nil)
  end

  it "a chave do lock não contém o CPF" do
    expect(described_class.lock_key(citizen.cpf).to_s).not_to include(citizen.cpf)
    expect(described_class.lock_key(citizen.cpf)).to eq(described_class.lock_key(citizen.cpf))
  end
end
