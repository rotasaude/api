require "rails_helper"

RSpec.describe Professionals::EndLink do
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

  it "segunda vez: already_ended" do
    described_class.call(link: link, by: admin)
    expect(described_class.call(link: link, by: admin).reason).to eq(:already_ended)
  end

  it "depois de encerrar, o mesmo par pode ser aberto de novo" do
    described_class.call(link: link, by: admin)
    again = Professionals::OpenLink.call(professional: doctor, health_unit_id: link.health_unit_id, cbo_code: "225125", by: admin)
    expect(again).to be_ok
  end
end
