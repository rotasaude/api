require "rails_helper"

RSpec.describe Professionals::CancelShift do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:admin) { staff_with("admin@cidade.gov.br", "municipal_admin") }
  let(:doctor) do
    Professional.create!(user: staff_with("medica@cidade.gov.br", "health_professional"), professional_name: "Helena",
                         council: "CRM", council_state: "PR", registration_number: "12345", cns: "700000000000005")
  end
  let(:link) do
    Professionals::OpenLink.call(professional: doctor, health_unit_id: create_unit.id, cbo_code: "225125", by: admin)
                           .payload[:link]
  end
  let(:shift) do
    day = Time.zone.tomorrow.in_time_zone
    Professionals::ScheduleShift.call(link: link, starts_at: day.change(hour: 7), ends_at: day.change(hour: 13), by: admin)
                                .payload[:shift]
  end

  it "cancela com motivo e publica professional.shift_cancelled" do
    expect(described_class.call(shift: shift, reason: "  troca de escala ", by: admin)).to be_ok
    expect(shift.reload).to have_attributes(cancel_reason: "troca de escala", cancelled_by_user: admin)
    expect(DomainEvent.where(name: "professional.shift_cancelled").sole.payload)
      .to eq("shift_id" => shift.id, "professional_id" => doctor.id, "professional_link_id" => link.id,
             "by_user_id" => admin.id)
  end

  it "sem motivo: reason_required; motivo com mais de 200: reason_too_long" do
    expect(described_class.call(shift: shift, reason: "  ", by: admin).reason).to eq(:reason_required)
    expect(described_class.call(shift: shift, reason: "x" * 201, by: admin).reason).to eq(:reason_too_long)
  end

  it "segunda vez: already_cancelled" do
    described_class.call(shift: shift, reason: "troca", by: admin)
    expect(described_class.call(shift: shift, reason: "outra", by: admin).reason).to eq(:already_cancelled)
  end
end
