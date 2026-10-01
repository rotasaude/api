require "rails_helper"

# ADR 0026: a trilha (imutável por 12 meses) só leva referência.
RSpec.describe "payload de triage.completed e triage.urgent" do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  it "publica só o triage_id, sem respostas nem classificação" do
    citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432")
    triage = completed_web_triage_for(citizen)

    event = DomainEvent.where(name: "triage.completed").find_by("payload->>'triage_id' = ?", triage.id)
    expect(event.payload).to eq("triage_id" => triage.id)
  end
end
