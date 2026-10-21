require "rails_helper"

# Bairro e telefone do par validado do wpda para o BPA-I; o telefone é dado
# pessoal e nunca aparece em inspect/to_s/pp (regra de Data com dado pessoal).
RSpec.describe Billing::PatientContact do
  let(:contact) { described_class::Contact.new(district: "Bairro Sigiloso", phone: "41998765432") }

  it "Contact nunca mostra bairro nem telefone em inspect, to_s, interpolação ou pp" do
    [ contact.inspect, contact.to_s, "#{contact}", PP.pp(contact, +"") ].each do |text|
      expect(text).not_to include("41998765432")
      expect(text).not_to include("Sigiloso")
    end
    expect(contact.inspect).to eq("#<Billing::PatientContact::Contact district_set=true phone_set=true>")
  end

  it "vazio para quem não tem par validado" do
    expect(described_class.for([ SecureRandom.uuid ])).to eq({})
  end

  context "com o par validado" do
    let(:pair) { exam_patient!(exam_seq!) }
    let(:patient) { pair.first }
    let(:citizen) { pair.last }

    def phone_for(raw)
      citizen.update!(phone: raw)
      described_class.for([ patient.id ]).fetch(patient.id).phone
    end

    it "telefone sem o 55, só com 10 ou 11 dígitos; senão, nada" do
      expect(phone_for("+55 (41) 99876-5432")).to eq("41998765432")
      expect(phone_for("+554133334444")).to eq("4133334444")
      expect(phone_for("4133334444")).to eq("4133334444")
      expect(phone_for("41999")).to be_nil
      expect(phone_for("123456789012")).to be_nil
    end

    it "o par validado mais recente vence, com o bairro dele" do
      citizen.update_columns(updated_at: 1.day.ago)
      Citizen.create!(cpf: citizen.cpf, phone: "+5541977776666", verification_level: "verified", patient_id: patient.id,
                      neighborhood: Neighborhood.create!(name: "Batel", source: "manual"))
      expect(described_class.for([ patient.id ]).fetch(patient.id)).to have_attributes(phone: "41977776666", district: "Batel")
    end
  end
end
