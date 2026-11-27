require "rails_helper"

# Módulo 26c, revisão final I1 (e Q26): o recálculo de todos os pedidos de uma
# cidade, depois de uma mudança de ajustes, fora da transação do consumidor.
# Cada pedido no seu próprio recálculo (uma transação curta por linha); uma
# linha que falha não para as outras e o log só tem o id e a classe.
RSpec.describe Regulation::RndsRecomputeAllJob, type: :job do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.zone.local(2026, 11, 20, 9, 0) }

  before do
    travel_to now
    rnds_regulation_city!(mock: false)
    tick_regulation_events!
  end

  def row!(request) = Regulation::RndsSync.recompute!(request.reload, create: true, now: Time.current)

  it "roda em cada cidade, um de cada vez, fora de IdempotentConsumer" do
    expect(described_class.ancestors).to include(EachCityJob)
    expect(described_class.ancestors).not_to include(IdempotentConsumer)
    expect(described_class.concurrency_key).to be_present
    expect(described_class.concurrency_limit).to eq(1)
  end

  it "cada recálculo na sua transação: nenhuma transação aberta em volta, e a linha que levanta não desfaz as outras" do
    requests = Array.new(3) { regulation_request! }
    requests.each { |request| row!(request) }
    broken = requests[1]
    RegulationRndsSync.update_all(desired_digest: "0" * 64, status: "idle", next_attempt_at: nil)
    baseline = ApplicationRecord.connection.open_transactions
    depths = []
    allow(Regulation::RndsSync).to receive(:recompute!).and_wrap_original do |original, request, **kwargs|
      depths << ApplicationRecord.connection.open_transactions
      raise "quebrado #{request.patient.cpf}" if request.id == broken.id

      original.call(request, **kwargs)
    end
    logged = []
    allow(Rails.logger).to receive(:error) { |message| logged << message }

    expect { described_class.perform_now }.not_to raise_error

    expect(depths).to eq([ baseline ] * 3)
    statuses = RegulationRndsSync.where(regulation_request_id: requests.map(&:id)).to_h { |sync| [ sync.regulation_request_id, sync.status ] }
    expect(statuses).to eq(requests[0].id => "queued", broken.id => "idle", requests[2].id => "queued")
    expect(logged).to eq([ "[Regulation::RndsRecomputeAllJob] regulation_request_id=#{broken.id} RuntimeError" ])
  end
end
