require "rails_helper"

# ADR 0035 (spec §3): a pessoa é o conjunto dos pares VALIDADOS do CPF
# (mais o paciente do 19a, quando existe). Par só declarado nunca entra.
RSpec.describe Timeline::Person do
  before { clinical_city! }

  def declared_twin_of(citizen)
    Citizen.create!(cpf: citizen.cpf, phone: "+5541977770001", verification_level: "declared")
  end

  it "pares que entram e saem: declarado, revogado e excluído ficam de fora (Review Focus 4)" do
    verified = verified_citizen!(31)
    twin = declared_twin_of(verified)
    other = verified_citizen!(32)
    person = described_class.for_cpf(verified.cpf)
    expect(person.citizen_ids).to eq([ verified.id ])
    expect(person.citizen_ids).not_to include(twin.id, other.id)
    expect(person.verified).to be(true)
    expect(person.patient_id).to be_nil

    verified.update!(verification_level: "declared")
    expect(described_class.for_cpf(verified.cpf)).to be_empty

    verified.update!(verification_level: "verified", erased_at: Time.current)
    expect(described_class.for_cpf(verified.cpf)).to be_empty
  end

  it "com paciente, junta os pares ligados a ele e os validados do CPF" do
    citizen = verified_citizen!(33)
    patient = Patients::Resolve.call(citizen).payload[:patient]
    person = described_class.for_patient(patient)
    expect(person.patient_id).to eq(patient.id)
    expect(person.citizen_ids).to eq([ citizen.id ])
    expect(described_class.for_cpf("#{citizen.cpf[0, 3]}.#{citizen.cpf[3, 3]}.#{citizen.cpf[6, 3]}-#{citizen.cpf[9, 2]}"))
      .to eq(person)
    expect(person.ref).to eq("patient:#{patient.id}")
  end

  it "for_citizen: validado vira a pessoa do CPF; declarado vê só o próprio par" do
    verified = verified_citizen!(34)
    twin = declared_twin_of(verified)
    expect(described_class.for_citizen(verified).citizen_ids).to eq([ verified.id ])
    own = described_class.for_citizen(twin)
    expect([ own.citizen_ids, own.verified, own.patient_id ]).to eq([ [ twin.id ], false, nil ])
    expect(own.ref).to eq("citizen:#{twin.id}")
  end

  it "CPF inválido ou vazio é a pessoa vazia; nome de exibição do paciente ou do par" do
    expect(described_class.for_cpf("123")).to be_empty
    expect(described_class.for_cpf(nil)).to be_empty
    citizen = verified_citizen!(35, social_name: "Bia")
    expect(described_class.for_cpf(citizen.cpf).display_name).to eq("Bia")
  end
end
