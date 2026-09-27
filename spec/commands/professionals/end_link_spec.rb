require "rails_helper"

RSpec.describe Professionals::EndLink do
  include ActiveSupport::Testing::TimeHelpers

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

  it "encerra com fim = agora e publica professional.unlinked" do
    result = described_class.call(link: link, by: admin)
    expect(result).to be_ok
    expect(link.reload).to have_attributes(ended_by_user: admin)
    expect(link.ended_at).to be_within(1.second).of(Time.current)
    expect(DomainEvent.where(name: "professional.unlinked").sole.payload).to include(
      "professional_link_id" => link.id, "cancelled_shift_ids" => []
    )
  end

  it "started_at no futuro (clock skew entre hosts): ended_at nunca fica antes do início" do
    skewed = ProfessionalLink.create!(professional: doctor, health_unit_id: create_unit.id, cbo_code: "225125",
                                      started_at: 1.second.from_now, started_by_user: admin)

    result = described_class.call(link: skewed, by: admin)

    expect(result).to be_ok
    expect(skewed.reload.ended_at).to eq(skewed.started_at)
  end

  it "segunda vez: already_ended" do
    described_class.call(link: link, by: admin)
    expect(described_class.call(link: link, by: admin).reason).to eq(:already_ended)
  end

  it "depois de encerrar, o mesmo par pode ser aberto de novo" do
    described_class.call(link: link, by: admin)
    again = Professionals::OpenLink.call(professional: doctor, health_unit_id: link.health_unit_id, cbo_code: "225125", by: admin)
    expect(again).to be_ok
  end

  describe "turnos do vínculo" do
    def schedule(starts_at, ends_at)
      Professionals::ScheduleShift.call(link: link, starts_at: starts_at, ends_at: ends_at, by: admin).payload[:shift]
    end

    it "cancela os futuros; mantém o que já passou e o que está em curso" do
      base = Time.zone.parse("2026-10-05 10:00")
      travel_to(base - 3.days) { link }
      past = travel_to(base - 2.days) { schedule(base - 1.day, base - 1.day + 4.hours) }
      current = travel_to(base - 2.days) { schedule(base - 2.hours, base + 2.hours) }
      future = travel_to(base - 2.days) { schedule(base + 1.day, base + 1.day + 6.hours) }

      result = travel_to(base) { described_class.call(link: link, by: admin) }
      expect(result.payload[:cancelled_shift_ids]).to eq([ future.id ])
      expect(future.reload).to have_attributes(cancel_reason: ProfessionalShift::LINK_ENDED_REASON, cancelled_by_user: admin)
      expect(past.reload.cancelled_at).to be_nil
      expect(current.reload.cancelled_at).to be_nil
    end
  end
end
