require "rails_helper"

# Módulo 26a, Task 10 (ADR 0044; contrato §7, §13 G1; plano do api, Desvio 8;
# overlay da Task 10): a falta. `missed` nunca é situação atual, nem por um
# instante: o andamento `missed` (record_event!) e UMA transição — closed na
# segunda falta, senão de volta a pending/external sem evento novo. version
# +1 por falta; a cota não é liberada.
RSpec.describe CareRegulation::Misses do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.zone.local(2026, 10, 6, 10, 0) }

  before do
    travel_to now
    regulation_city!
    tick_regulation_events!
  end

  let(:regulator) { regulation_regulator! }
  let(:offer) { offer!(provider: external_provider!) }

  def apply!(request)
    ApplicationRecord.transaction do
      request.lock!(CareRegulation::Decide::LOCK)
      described_class.apply!(request: request, by: regulator)
    end
  end

  def used = CareRegulation::Quota.used([ offer.id ]).fetch(offer.id)
  def published(name) = DomainEvent.where(name: "regulation_request.#{name}").count

  it "primeira falta: missed no andamento e de volta a pending (version +1), sem evento novo além do missed" do
    request = reauthorize!(regulation_request!, offer: offer)
    version = request.version
    requested_at = request.requested_at
    due_on = request.due_on
    created = published("created")
    complemented = published("complemented")

    expect(apply!(request)).to eq(request)
    expect(request.reload).to have_attributes(status: "pending", misses: 1, version: version + 1, requested_at: requested_at,
                                              due_on: due_on, scheduled_at: nil, schedule_place: nil, appointment_request_id: nil)
    expect(request.events.map(&:status).last(2)).to eq(%w[missed pending])
    expect(request.events.last(2).map(&:by_user_id)).to eq([ regulator.id, regulator.id ])
    expect(DomainEvent.where(name: "regulation_request.missed").map(&:payload))
      .to eq([ { "regulation_request_id" => request.id, "user_id" => regulator.id } ])
    expect([ published("created"), published("complemented") ]).to eq([ created, complemented ])
    expect(used).to eq(1) # a falta não devolve a vaga
    expect(request.authorizations.sole.released_at).to be_nil
  end

  it "segunda falta: missed e closed, com os dois eventos; outcome missed" do
    request = reauthorize!(regulation_request!, offer: offer)
    apply!(request)
    request = reauthorize!(request.reload, offer: offer)
    version = request.version
    apply!(request)
    expect(request.reload).to have_attributes(status: "closed", misses: 2, version: version + 1)
    expect(request.events.map(&:status).last(2)).to eq(%w[missed closed])
    expect([ published("missed"), published("closed") ]).to eq([ 2, 1 ])
    expect(CareRegulation::Json.request(request)[:outcome]).to eq("missed")
    expect(used).to eq(2)
  end

  it "missed nunca é situação atual: nenhuma linha em missed e nenhum update! com status missed" do
    request = reauthorize!(regulation_request!, offer: offer)
    statuses = []
    allow_any_instance_of(RegulationRequest).to receive(:update!).and_wrap_original do |original, *args, **kwargs|
      attrs = args.first || kwargs
      statuses << attrs.to_h.symbolize_keys[:status]
      expect(RegulationRequest.where(status: "missed")).to be_empty
      original.call(*args, **kwargs)
    end
    apply!(request)
    request = reauthorize!(request.reload, offer: offer)
    apply!(request)
    expect(statuses.compact).not_to include("missed")
    expect(statuses.compact).to include("pending", "closed")
    expect(RegulationRequest.where(status: "missed")).to be_empty
  end

  it "externo regulado pelo estado: a primeira falta volta a external, sem publicar regulation_request.external" do
    request = regulation_request!(status: "external")
    # Agendamento externo lançado pelo regulador (Task 11): external → scheduled
    # pela Transition, como o comando fará.
    ApplicationRecord.transaction do
      request.lock!(CareRegulation::Decide::LOCK)
      expect(CareRegulation::Transition.call(request: request, to: "scheduled", by: regulator,
                                             changes: { scheduled_at: 3.days.from_now, schedule_place: "Hospital Regional" })).to be_ok
    end
    externals = published("external")
    apply!(request)
    expect(request.reload).to have_attributes(status: "external", state_regulated: true, misses: 1, scheduled_at: nil,
                                              schedule_place: nil)
    expect(request.events.map(&:status).last(2)).to eq(%w[missed external])
    expect(published("external")).to eq(externals)
    expect(published("missed")).to eq(1)
  end

  it "authorization no JSON só quando vigente: falta → pending → nula; reautorizar → a nova" do
    request = reauthorize!(regulation_request!, offer: offer)
    first = request.authorizations.sole
    expect(CareRegulation::Json.request(request)[:authorization]).to include(at: first.created_at.iso8601)
    apply!(request)
    expect(CareRegulation::Json.request(request.reload)[:authorization]).to be_nil
    travel_to(now + 1.hour)
    request = reauthorize!(request, offer: offer)
    second = request.authorizations.last
    expect(second.id).not_to eq(first.id)
    expect(CareRegulation::Json.request(request)[:authorization]).to include(offer_id: offer.id, at: second.created_at.iso8601)
  end

  it "só de authorized/scheduled; misses nunca passa de 2 (CHECK)" do
    request = regulation_request!
    expect { apply!(request) }.to raise_error(ArgumentError, /falta só de/)
    expect(request.reload).to have_attributes(status: "pending", misses: 0)
    expect { request.update_columns(misses: 3) }.to raise_error(ActiveRecord::StatementInvalid, /ck_regulation_requests_misses/)
  end
end
