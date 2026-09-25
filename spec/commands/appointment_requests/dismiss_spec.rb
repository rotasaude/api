require "rails_helper"

RSpec.describe AppointmentRequests::Dismiss do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:reception) { staff_with("recepcao@cidade.gov.br", "citizen_verifier") }
  let(:doctor) { staff_with("medica@cidade.gov.br", "health_professional") }
  let(:req) do
    a = in_care!(waiting_attendance(Citizen.create!(cpf: "52998224725", phone: "+5541998765432"), unit: unit,
                                    by: reception), by: doctor)
    a.update!(status: "closed", outcome: "return", closed_by_user: doctor, closed_at: Time.current)
    request_for(a)
  end

  it "encerra com justificativa e publica" do
    r = described_class.call(request: req, reason: "cidadão mudou de cidade", health_unit_id: unit.id, by: reception)
    expect(r).to be_ok
    expect(req.reload).to have_attributes(status: "closed", closed_reason: "dismissed", closed_by_user_id: reception.id)
    expect(DomainEvent.where(name: "appointment_request.closed").count).to eq(1)
  end

  it "justificativa curta: reason_too_short; pedido fechado: request_not_open" do
    expect(described_class.call(request: req, reason: "curto", health_unit_id: unit.id, by: reception).reason)
      .to eq(:reason_too_short)
    described_class.call(request: req, reason: "cidadão mudou de cidade", health_unit_id: unit.id, by: reception)
    expect(described_class.call(request: req.reload, reason: "de novo, por engano", health_unit_id: unit.id,
                                by: reception).reason).to eq(:request_not_open)
  end
end
