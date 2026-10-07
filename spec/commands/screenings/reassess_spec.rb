# spec/commands/screenings/reassess_spec.rb
require "rails_helper"

# ADR 0030 (spec §3.2, §4): reavaliar enquanto a pessoa espera, com destino
# same_day; cada reavaliação é uma revisão nova.
RSpec.describe Screenings::Reassess do
  before { Current.city = TEST_CITY_A; ciap2_release! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:nurse) { screener!(unit) }
  let(:attendance) { walk_in_attendance!(unit, citizen: screening_citizen!(1)) }
  let(:screening) do
    started = Screenings::Start.call(attendance: attendance, by: nurse).payload[:screening]
    Screenings::Complete.call(screening: started, revision_params: revision_params(final_color: "green"),
                              destination: "same_day", destination_params: {}, by: nurse)
    started.reload
  end

  it "nova revisão vira a corrente; a anterior fica; evento só com ids" do
    first = screening.current_revision
    result = described_class.call(screening: screening, by: nurse,
                                  revision_params: revision_params(final_color: "yellow", vitals: { "spo2" => 93 }))
    expect(result).to be_ok
    revision = result.payload[:revision]
    expect(screening.reload.current_revision_id).to eq(revision.id)
    expect(screening.revisions.count).to eq(2)
    expect(first.reload.final_color).to eq("green")
    expect(DomainEvent.where(name: "screening.reassessed").sole.payload)
      .to eq("screening_id" => screening.id, "revision_id" => revision.id, "final_color" => "yellow")
  end

  it "não reavalia escuta em curso, com outro destino, nem atendimento que saiu da espera" do
    other = walk_in_attendance!(unit, citizen: screening_citizen!(2))
    in_progress = Screenings::Start.call(attendance: other, by: nurse).payload[:screening]
    expect(described_class.call(screening: in_progress, by: nurse, revision_params: revision_params).reason)
      .to eq(:not_reassessable)
    screening.attendance.update!(status: "in_care", called_by_user: nurse, called_at: Time.current)
    expect(described_class.call(screening: screening.reload, by: nurse, revision_params: revision_params).reason)
      .to eq(:not_reassessable)
  end

  it "entrada inválida responde antes do estado" do
    expect(described_class.call(screening: screening, by: nurse, revision_params: revision_params(ciap2_code: "Z99")).reason)
      .to eq(:invalid_ciap2)
  end
end
