# spec/services/screenings/suggest_spec.rb
require "rails_helper"

# Sugestão com o protocolo ativo de acolhimento e o perfil do par.
RSpec.describe Screenings::Suggest do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:citizen) { screening_citizen!(1, age: 61) }

  it "sem protocolo ativo: sem sugestão (Review Focus 3)" do
    expect(described_class.call(citizen: citizen, ciap2_code: "R05", vitals: {}, bmi: nil))
      .to eq(color: nil, matched: [], protocol_definition_id: nil)
  end

  it "com o acolhimento ativo, sugere e diz qual versão decidiu" do
    protocol = acolhimento!
    result = described_class.call(citizen: citizen, ciap2_code: "K86", vitals: { "systolic" => 185, "diastolic" => 110 }, bmi: nil)
    expect(result).to eq(color: "red", matched: [ 0 ], protocol_definition_id: protocol.id)
  end

  it "um protocolo de triagem ativo nunca é usado para cor" do
    active_protocol!("saude-do-idoso")
    expect(Screenings::ActiveProtocol.current).to be_nil
  end
end
