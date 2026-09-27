require "rails_helper"

RSpec.describe Professionals::ScheduleShift do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:admin) { staff_with("admin@cidade.gov.br", "municipal_admin") }
  let(:ubs) { create_unit("UBS Jardim") }
  let(:upa) { create_unit("UPA Centro", kind: "upa") }
  let(:doctor) do
    Professional.create!(user: staff_with("medica@cidade.gov.br", "health_professional"), professional_name: "Helena",
                         council: "CRM", council_state: "PR", registration_number: "12345", cns: "700000000000005")
  end
  let(:ubs_link) { open_link(ubs, "225125") }
  let(:upa_link) { open_link(upa, "225124") }
  let(:tomorrow) { Time.zone.tomorrow }

  def open_link(unit, cbo)
    Professionals::OpenLink.call(professional: doctor, health_unit_id: unit.id, cbo_code: cbo, by: admin).payload[:link]
  end

  def at(day, hour) = day.in_time_zone.change(hour: hour)

  def schedule(link, starts_at, ends_at)
    described_class.call(link: link, starts_at: starts_at, ends_at: ends_at, by: admin)
  end

  it "lança e publica professional.shift_scheduled só com ids" do
    shift = schedule(ubs_link, at(tomorrow, 7), at(tomorrow, 13)).payload[:shift]
    expect(shift).to have_attributes(professional_id: doctor.id, created_by_user: admin)
    expect(DomainEvent.where(name: "professional.shift_scheduled").sole.payload).to eq(
      "shift_id" => shift.id, "professional_link_id" => ubs_link.id, "professional_id" => doctor.id,
      "by_user_id" => admin.id
    )
  end

  it "aceita ISO 8601 em string" do
    expect(schedule(ubs_link, at(tomorrow, 7).iso8601, at(tomorrow, 13).iso8601)).to be_ok
  end

  it "plantão 19h–07h e plantão de 24h exatas são aceitos; 24h01 não" do
    expect(schedule(upa_link, at(tomorrow, 19), at(tomorrow + 1, 7))).to be_ok
    expect(schedule(upa_link, at(tomorrow + 3, 7), at(tomorrow + 4, 7))).to be_ok
    expect(schedule(upa_link, at(tomorrow + 6, 7), at(tomorrow + 7, 7) + 1.minute).reason).to eq(:invalid_shift)
  end

  it "fim igual ou antes do início, data ilegível e antes do início do vínculo: invalid_shift" do
    expect(schedule(ubs_link, at(tomorrow, 13), at(tomorrow, 13)).reason).to eq(:invalid_shift)
    expect(schedule(ubs_link, at(tomorrow, 13), at(tomorrow, 7)).reason).to eq(:invalid_shift)
    expect(schedule(ubs_link, "ontem", at(tomorrow, 7)).reason).to eq(:invalid_shift)
    expect(schedule(ubs_link, ubs_link.started_at - 1.hour, ubs_link.started_at + 1.hour).reason).to eq(:invalid_shift)
  end

  it "sobrepor turno do mesmo profissional em OUTRA unidade: shift_overlap nomeando o conflito" do
    schedule(ubs_link, at(tomorrow, 7), at(tomorrow, 13))
    result = schedule(upa_link, at(tomorrow, 12), at(tomorrow, 18))
    expect(result.reason).to eq(:shift_overlap)
    expect(result.details[:conflict]).to eq(unit_name: "UBS Jardim", starts_at: at(tomorrow, 7).iso8601,
                                            ends_at: at(tomorrow, 13).iso8601)
  end

  it "encostar (fim de um = início do outro) não é sobreposição" do
    schedule(ubs_link, at(tomorrow, 7), at(tomorrow, 13))
    expect(schedule(upa_link, at(tomorrow, 13), at(tomorrow, 19))).to be_ok
  end

  it "turno cancelado não conta como conflito" do
    first = schedule(ubs_link, at(tomorrow, 7), at(tomorrow, 13)).payload[:shift]
    Professionals::CancelShift.call(shift: first, reason: "troca de escala", by: admin)
    expect(schedule(upa_link, at(tomorrow, 7), at(tomorrow, 13))).to be_ok
  end

  it "vínculo encerrado: link_ended" do
    Professionals::EndLink.call(link: ubs_link, by: admin)
    expect(schedule(ubs_link, at(tomorrow, 7), at(tomorrow, 13)).reason).to eq(:link_ended)
  end
end
