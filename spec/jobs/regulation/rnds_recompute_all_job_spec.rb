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

  # Q26: o reenfileiramento por ajuste vai na faixa da carga inicial e pula o terminal com aceite de mais de 30 dias.
  it "linhas reenfileiradas na faixa da carga inicial; terminal com último aceite de mais de 30 dias fica de fora" do
    live = regulation_request!
    recent_end = regulation_request!
    old_end = regulation_request!
    never_accepted_end = regulation_request!
    [ live, recent_end, old_end, never_accepted_end ].each { |request| row!(request) }
    [ recent_end, old_end, never_accepted_end ].each { |request| request.update_columns(status: "cancelled") }
    accepted_at = { live => now - 40.days, recent_end => now - 29.days, old_end => now - 31.days }
    accepted_at.each do |request, at|
      sync = RegulationRndsSync.find_by!(regulation_request_id: request.id)
      sync.update_columns(status: "idle", next_attempt_at: nil, last_rnds_id: "RA#{SecureRandom.hex(4)}", last_accepted_at: at,
                          sent_status: sync.desired_status, sent_digest: sync.desired_digest)
    end
    RegulationRndsSync.find_by!(regulation_request_id: never_accepted_end.id).update_columns(status: "blocked", blocked_reasons: [ "missing_diagnosis" ])
    digests = RegulationRndsSync.pluck(:regulation_request_id, :desired_digest).to_h

    rnds_settings!(priority_by_color: RegulationRndsSetting.current.priority_by_color.transform_values { "urgent" })
    described_class.perform_now

    rows = RegulationRndsSync.all.index_by(&:regulation_request_id)
    expect(rows.fetch(live.id)).to have_attributes(status: "queued", initial_load: true, enqueued_at: Time.current)
    expect(rows.fetch(recent_end.id)).to have_attributes(status: "queued", initial_load: true)
    expect(rows.fetch(old_end.id)).to have_attributes(status: "idle", initial_load: false, desired_digest: digests.fetch(old_end.id))
    expect(rows.fetch(never_accepted_end.id).desired_digest).not_to eq(digests.fetch(never_accepted_end.id))
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
