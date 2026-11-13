require "rails_helper"

# Módulo 24b (ADR 0052; contrato §7, §13, §16 Q54): o corpo da recusa das rotas
# /collective_activities. `duplicate_participant` leva `confirmable` (o
# dashboard só oferece "É outra pessoa" com true); as outras recusas não. A
# rota POST /collective_activities chega na Task 15: aqui, o render_failure
# que ela usa.
RSpec.describe CollectiveActivities::BaseController, type: :controller do
  let(:host) do
    described_class.new.tap do |controller|
      controller.define_singleton_method(:render) { |json:, status:| @rendered = [ json, status ] }
      controller.define_singleton_method(:rendered) { @rendered }
    end
  end

  def render_failure(result) = host.send(:render_failure, result).then { host.rendered }

  it "duplicate_participant: 422 com path e confirmable (true ou false), sem candidates" do
    soft = Result.fail(:duplicate_participant, details: { path: "participants[1]", confirmable: true })
    expect(render_failure(soft)).to eq([ { error: "duplicate_participant", path: "participants[1]", confirmable: true },
                                         :unprocessable_entity ])
    hard = Result.fail(:duplicate_participant, details: { path: "participants[2]", confirmable: false })
    expect(render_failure(hard)).to eq([ { error: "duplicate_participant", path: "participants[2]", confirmable: false },
                                         :unprocessable_entity ])
  end

  it "as outras recusas não ganham confirmable" do
    result = Result.fail(:invalid_collective_activity, details: { path: "health_topics[0]", confirmable: true })
    expect(render_failure(result)).to eq([ { error: "invalid_collective_activity", path: "health_topics[0]" }, :unprocessable_entity ])
  end
end
