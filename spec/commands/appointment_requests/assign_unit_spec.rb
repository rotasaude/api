require "rails_helper"

RSpec.describe AppointmentRequests::AssignUnit do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:reception) { staff_with("recepcao-fila@cidade.gov.br", "citizen_verifier") }
  let(:unit) { create_unit }
  let(:req) { triage_request!(Citizen.create!(cpf: "52998224725", phone: "+5541998765432"), unit: nil) }

  it "atribui uma vez, com evento só de ids; a segunda é already_assigned" do
    expect(described_class.call(request: req, unit_id: unit.id, by: reception)).to be_ok
    expect(req.reload.target_unit_id).to eq(unit.id)
    expect(DomainEvent.where(name: "appointment_request.unit_assigned").sole.payload)
      .to eq("request_id" => req.id, "unit_id" => unit.id, "by_user_id" => reception.id)
    expect(described_class.call(request: req, unit_id: create_unit("UBS Sul").id, by: reception).reason).to eq(:already_assigned)
    expect(req.reload.target_unit_id).to eq(unit.id)
    expect(DomainEvent.where(name: "appointment_request.unit_assigned").count).to eq(1)
  end

  it "unidade inativa, inexistente ou id malformado: invalid_unit" do
    expect(described_class.call(request: req, unit_id: create_unit("UBS Fechada", active: false).id, by: reception).reason).to eq(:invalid_unit)
    expect(described_class.call(request: req, unit_id: SecureRandom.uuid, by: reception).reason).to eq(:invalid_unit)
    expect(described_class.call(request: req, unit_id: "x", by: reception).reason).to eq(:invalid_unit)
    expect(described_class.call(request: req, unit_id: nil, by: reception).reason).to eq(:invalid_unit)
    expect(req.reload.target_unit_id).to be_nil
    expect(DomainEvent.where(name: "appointment_request.unit_assigned")).to be_empty
  end

  it "pedido que não está aberto: request_not_open, sem atribuir" do
    req.update!(status: "scheduled")
    expect(described_class.call(request: req, unit_id: unit.id, by: reception).reason).to eq(:request_not_open)
    expect(req.reload.target_unit_id).to be_nil
  end
end
