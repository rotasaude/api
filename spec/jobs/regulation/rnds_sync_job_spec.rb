require "rails_helper"

# Módulo 26c, Task 10 (contrato §2, gatilhos; pré-voo B3, I12): o consumidor
# dos eventos que recalcula o estado desejado de cada pedido. Cada evento só
# diz quais pedidos olhar; a entrega repetida processa uma vez
# (IdempotentConsumer). Os eventos saem dos comandos reais.
RSpec.describe Regulation::RndsSyncJob, type: :job do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.zone.local(2026, 11, 20, 9, 0) }
  let(:regulator) { regulation_regulator! }
  let(:offer) { offer!(provider: external_provider!) }

  before do
    travel_to now
    rnds_regulation_city!(mock: false)
    tick_regulation_events!
  end

  def deliver(event, event_id: event.id)
    described_class.new.perform(event_id: event_id, event_name: event.name, city_slug: Current.city.slug, payload: event.payload)
  end

  def last_event(name) = DomainEvent.where(name: name).order(:occurred_at, :id).last!

  def row!(request) = Regulation::RndsSync.recompute!(request.reload, create: true, now: Time.current)

  # O aceite da Task 12, simulado (o desejado vira o enviado).
  def accept!(sync)
    sync.reload
    RegulationRndsDelivery.create!(regulation_rnds_sync: sync, kind: "create", mira_status: sync.desired_status, digest: sync.desired_digest,
                                   sent_at: Time.current, accepted_at: Time.current, rnds_id: "RA#{SecureRandom.hex(8)}", http_status: 201)
    sync.update!(last_rnds_id: "RA#{SecureRandom.hex(8)}", last_accepted_at: Time.current, sent_status: sync.desired_status,
                 sent_digest: sync.desired_digest, status: "idle", next_attempt_at: nil)
    travel 1.second
    sync.reload
  end

  def recomputed_ids
    ids = []
    allow(Regulation::RndsSync).to receive(:recompute!).and_wrap_original do |original, request, **kwargs|
      ids << request.id
      original.call(request, **kwargs)
    end
    ids
  end

  it "o publish dos eventos do pedido enfileira o consumidor" do
    expect { regulation_request! }.to have_enqueued_job(described_class).with(hash_including(event_name: "regulation_request.created"))
  end

  it "evento do pedido com o interruptor ligado cria a linha" do
    request = regulation_request!
    deliver(last_event("regulation_request.created"))
    expect(RegulationRndsSync.find_by!(regulation_request_id: request.id)).to have_attributes(status: "queued", desired_status: "pending")
  end

  it "care_offer.changed recalcula só os pedidos da oferta" do
    mine = reauthorize!(regulation_request!, offer: offer)
    theirs = reauthorize!(regulation_request!, offer: offer!(provider: external_provider!))
    [ mine, theirs ].each { |request| row!(request) }
    ids = recomputed_ids

    result = CareRegulation::SaveOffer.call(offer: offer, attrs: { "quantity" => 9 }, by: regulation_admin!)
    raise "oferta recusada: #{result.reason}" if result.failure?

    deliver(last_event("care_offer.changed"))
    expect(ids).to eq([ mine.id ])
  end

  it "rejected + care_offer.changed sem mudar o conteúdo → segue rejected (pré-voo B3)" do
    request = reauthorize!(regulation_request!, offer: offer)
    row!(request).update_columns(status: "rejected", last_error_codes: [ "EHR-ERR999" ])

    result = CareRegulation::SaveOffer.call(offer: offer, attrs: { "quantity" => 9 }, by: regulation_admin!)
    raise "oferta recusada: #{result.reason}" if result.failure?

    deliver(last_event("care_offer.changed"))
    expect(RegulationRndsSync.find_by!(regulation_request_id: request.id))
      .to have_attributes(status: "rejected", last_error_codes: [ "EHR-ERR999" ])
  end

  it "health_unit.changed do CNES da unidade solicitante recalcula o pedido" do
    request = regulation_request!
    sync = accept!(row!(request))
    unit = request.requester_unit

    expect { unit.update!(name: "#{unit.name} (renomeada)") }.not_to change { DomainEvent.where(name: "health_unit.changed").count }
    expect { create_unit("UBS Nova", cnes: regulation_cnes) }.not_to change { DomainEvent.where(name: "health_unit.changed").count }
    unit.update!(cnes: regulation_cnes)
    event = last_event("health_unit.changed")
    expect(event.payload).to eq("health_unit_id" => unit.id)

    deliver(event)
    expect(sync.reload).to have_attributes(status: "queued", desired_status: "pending")
    expect(sync.desired_digest).not_to eq(sync.sent_digest)
  end

  # I1: o recálculo de todos sai da transação do consumidor (Regulation::RndsRecomputeAllJob).
  it "regulation_rnds.settings_changed enfileira o recálculo de todos (e, com send_external, cria os regulados pelo estado)" do
    first = regulation_request!
    second = regulation_request!
    syncs = [ first, second ].map { |request| accept!(row!(request)) }
    external = regulation_request!(status: "external")
    ids = recomputed_ids

    rnds_settings!(priority_by_color: { "red" => "urgent", "yellow" => "urgent", "green" => "routine", "blue" => "routine" },
                   send_external: true)
    expect { deliver(last_event("regulation_rnds.settings_changed")) }.to have_enqueued_job(Regulation::RndsRecomputeAllJob).with(no_args)
    expect(ids).to be_empty # nada na transação do consumidor
    syncs.each { |sync| expect(sync.reload.status).to eq("idle") }

    Regulation::RndsRecomputeAllJob.perform_now
    expect(ids).to contain_exactly(first.id, second.id, external.id)
    syncs.each { |sync| expect(sync.reload).to have_attributes(status: "queued", sent_status: "pending") }
    expect(RegulationRndsSync.find_by!(regulation_request_id: external.id))
      .to have_attributes(status: "queued", desired_status: "pending", initial_load: true)
  end

  it "settings_changed com o interruptor desligado só recalcula as linhas existentes" do
    accept!(row!(regulation_request!))
    external = regulation_request!(status: "external")
    Platform::Features.set!(city: Current.city, key: Regulation::RndsGate::KEY, enabled: false, maintainer: ledi_maintainer!)

    rnds_settings!(send_external: true)
    deliver(last_event("regulation_rnds.settings_changed"))
    Regulation::RndsRecomputeAllJob.perform_now
    expect(RegulationRndsSync.find_by(regulation_request_id: external.id)).to be_nil
  end

  # Q27: prazos e lista do enfermeiro não entram no documento.
  it "care_regulation.settings_changed não enfileira o consumidor" do
    admin = regulation_admin!
    expect { CareRegulation::SaveDeadlines.call(attrs: { "red" => 2, "yellow" => 30, "green" => 90, "blue" => 180 }, by: admin) }
      .not_to have_enqueued_job(described_class)
    expect(DomainEvent.where(name: "care_regulation.settings_changed").count).to eq(1) # controle: o evento saiu
  end

  it "o mesmo evento duas vezes não duplica" do
    request = regulation_request!
    ids = recomputed_ids
    event = last_event("regulation_request.created")

    deliver(event)
    deliver(event)
    expect(ids).to eq([ request.id ])
    expect(RegulationRndsSync.where(regulation_request_id: request.id).count).to eq(1)
    expect(DomainEvent.where(name: "regulation_rnds.queued").count).to eq(1)
  end

  it "evento publicado só com ids" do
    request = regulation_request!
    deliver(last_event("regulation_request.created"))
    sync = RegulationRndsSync.find_by!(regulation_request_id: request.id)

    expect(last_event("regulation_rnds.queued").payload).to eq("regulation_rnds_sync_id" => sync.id, "regulation_request_id" => request.id)
    patient = request.patient
    text = DomainEvent.where(name: %w[regulation_rnds.queued health_unit.changed]).map { |e| e.payload.to_json }.join
    [ patient.cpf, patient.cns, request.cid10 ].compact.each { |secret| expect(text).not_to include(secret) }
  end
end
