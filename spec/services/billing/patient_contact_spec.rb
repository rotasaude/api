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
end
