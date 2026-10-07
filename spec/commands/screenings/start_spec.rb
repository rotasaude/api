# spec/commands/screenings/start_spec.rb
require "rails_helper"

# ADR 0030 (spec §3.2): atendimento waiting, escopo da unidade, vínculo e CBO.
RSpec.describe Screenings::Start do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:nurse) { screener!(unit) }
  let(:attendance) { walk_in_attendance!(unit, citizen: screening_citizen!(1)) }

  it "inicia: em curso, autor, vínculo e CBO; evento só com ids" do
    result = described_class.call(attendance: attendance, by: nurse)
    expect(result).to be_ok
    screening = result.payload[:screening]
    link = nurse.professional.links.active.sole
    expect(screening).to have_attributes(status: "in_progress", started_by_user_id: nurse.id,
                                         professional_link_id: link.id, cbo_code: "223505", attendance_id: attendance.id)
    expect(DomainEvent.where(name: "screening.started").sole.payload)
      .to eq("screening_id" => screening.id, "attendance_id" => attendance.id, "user_id" => nurse.id)
  end

  it "já em curso ou concluída → already_screening; abandonada é retomada por outra" do
    first = described_class.call(attendance: attendance, by: nurse).payload[:screening]
    expect(described_class.call(attendance: attendance, by: nurse).reason).to eq(:already_screening)
    Screenings::Abandon.call(screening: first, by: nurse)
    tech = screener!(unit, cbo: "322205")
    resumed = described_class.call(attendance: attendance, by: tech)
    expect(resumed).to be_ok
    expect(resumed.payload[:screening].id).to eq(first.id)
    expect(first.reload).to have_attributes(status: "in_progress", started_by_user_id: tech.id, cbo_code: "322205")
  end

  it "escuta concluída com destino same_day (atendimento segue aguardando) → already_screening" do
    ciap2_release!
    started = described_class.call(attendance: attendance, by: nurse).payload[:screening]
    completed = Screenings::Complete.call(screening: started, revision_params: revision_params, destination: "same_day",
                                          destination_params: {}, by: nurse)
    expect(completed).to be_ok
    expect(attendance.reload.status).to eq("waiting")
    expect(described_class.call(attendance: attendance, by: screener!(unit, cbo: "322205")).reason)
      .to eq(:already_screening)
    expect(started.reload.status).to eq("completed")
  end

  it "escopo: walk_in não exige escuta de quem tem horário; all exige" do
    scheduled = scheduled_attendance!(unit, citizen: screening_citizen!(2))
    expect(described_class.call(attendance: scheduled, by: nurse).reason).to eq(:screening_not_required)
    unit.update!(screening_scope: "all")
    expect(described_class.call(attendance: scheduled.reload, by: nurse)).to be_ok
  end

  it "atendimento que não está aguardando; autorização" do
    attendance.update!(status: "in_care", called_by_user: nurse, called_at: Time.current)
    expect(described_class.call(attendance: attendance, by: nurse).reason).to eq(:not_waiting)
    other = walk_in_attendance!(unit, citizen: screening_citizen!(3))
    expect(described_class.call(attendance: other, by: reception!).reason).to eq(:missing_role)
    expect(described_class.call(attendance: other, by: screener!(create_unit("UBS Outra"))).reason).to eq(:missing_link)
    expect(described_class.call(attendance: other, by: screener!(unit, cbo: "322405")).reason).to eq(:cbo_not_allowed)
  end
end
