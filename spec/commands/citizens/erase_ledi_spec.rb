require "rails_helper"

# api#43: a exclusão confirmada chama a limpeza da fila para os pares do CPF.
RSpec.describe Citizens::Erase, "fila LEDI" do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  it "chama Ledi::CitizenSources.scrub! com os ids dos pares" do
    citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432")
    completed_web_triage_for(citizen)
    verifier = User.create!(email_address: "v-#{SecureRandom.hex(3)}@x.com", password: "secret123")
    admin = User.create!(email_address: "a-#{SecureRandom.hex(3)}@x.com", password: "secret123")
    request = Citizens::RequestErasure.call(cpf: citizen.cpf, document_checked: true, by: verifier).payload[:request]
    allow(Ledi::CitizenSources).to receive(:scrub!).and_call_original

    expect(described_class.call(request: request, by: admin)).to be_ok
    expect(Ledi::CitizenSources).to have_received(:scrub!).with([ citizen.id ])
  end
end
