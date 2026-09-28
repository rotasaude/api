require "rails_helper"

# ADR 0023: o bairro do caso é o copiado na triagem raiz (a própria, ou a do
# pedido do horário); sem triagem nenhuma, o bairro atual do cidadão.
RSpec.describe Attendance, "#territory_neighborhood_id" do
  let(:centro) { Neighborhood.create!(name: "Centro", source: "seed") }
  let(:batel) { Neighborhood.create!(name: "Batel", source: "seed") }
  let(:citizen) { Citizen.new(neighborhood: batel) }

  it "atendimento por triagem: o bairro da triagem" do
    triage = Triage.new(neighborhood: centro)
    expect(described_class.new(citizen: citizen, triage: triage).territory_neighborhood_id).to eq(centro.id)
  end

  it "triagem sem bairro: nil (não cai para o bairro atual)" do
    expect(described_class.new(citizen: citizen, triage: Triage.new).territory_neighborhood_id).to be_nil
  end

  it "atendimento por horário: o bairro da triagem raiz do pedido" do
    request = AppointmentRequest.new(root_triage: Triage.new(neighborhood: centro))
    attendance = described_class.new(citizen: citizen, appointment: Appointment.new(request: request))
    expect(attendance.territory_neighborhood_id).to eq(centro.id)
  end

  it "sem triagem nenhuma: o bairro atual do cidadão" do
    expect(described_class.new(citizen: citizen).territory_neighborhood_id).to eq(batel.id)
  end
end
