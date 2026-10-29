require "rails_helper"

# Módulo 26a, Task 10 (ADR 0044; contrato §7, §13 G1, G6; plano do api,
# Desvio 7, Review Focus 2): o consumidor dos eventos do 17. Cada evento só
# diz qual pedido de agendamento olhar; a entrega repetida processa uma vez
# (IdempotentConsumer/ProcessedEvent) e a ordem de chegada não importa.
RSpec.describe CareRegulation::AppointmentSyncJob, type: :job do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.zone.local(2026, 10, 6, 10, 0) }

  before do
    travel_to now
    regulation_city!
    tick_regulation_events!
  end

  let(:setup) { own_authorized_request! }
  let(:request) { setup.fetch(:regulation_request) }
  let(:appointment_request) { setup.fetch(:appointment_request) }

  def deliver(event, event_id: event.id)
    described_class.new.perform(event_id: event_id, event_name: event.name, city_slug: Current.city.slug, payload: event.payload)
  end

  def deliver_payload(name, payload)
    described_class.new.perform(event_id: SecureRandom.uuid, event_name: name, city_slug: Current.city.slug,
                                payload: payload.deep_stringify_keys)
  end

  def event_for(name, **payload_match)
    scope = DomainEvent.where(name: name)
    payload_match.each { |key, value| scope = scope.where("payload->>? = ?", key.to_s, value) }
    scope.order(:occurred_at, :id).last!
  end

  it "o publish dos eventos do 17 enfileira o consumidor" do
    expect { schedule_regulated!(appointment_request, at: 3.days.from_now.change(hour: 9)) }
      .to have_enqueued_job(described_class).with(hash_including(event_name: "appointment.scheduled"))
  end

  it "cada evento resolve o pedido de agendamento certo" do
    appointment = schedule_regulated!(appointment_request, at: 3.days.from_now.change(hour: 9))
    id = appointment_request.id
    payloads = {
      "appointment.scheduled" => { appointment_id: appointment.id, appointment_request_id: id, health_unit_id: SecureRandom.uuid },
      "appointment.checked_in" => { appointment_id: appointment.id, appointment_request_id: id },
      "appointment.no_show" => { appointment_id: appointment.id, appointment_request_id: id },
      "appointment.expired" => { appointment_id: appointment.id, appointment_request_id: id },
      "appointment.booked" => { appointment_id: SecureRandom.uuid, request_id: id, booking_kind: "slot" },
      "appointment.moved" => { from_appointment_id: SecureRandom.uuid, to_appointment_id: appointment.id, to_unit_id: SecureRandom.uuid },
      "appointment.cancelled" => { appointment_id: appointment.id, by: "citizen" },
      "appointment_request.closed" => { appointment_request_id: id, closed_reason: "fulfilled" },
      "appointment_request.moved" => { from_request_id: SecureRandom.uuid, to_request_id: id },
      "appointment_request.created" => { appointment_request_id: id, regulation_request_id: request.id }
    }
    expect(payloads.keys).to match_array(described_class::EVENTS)
    seen = []
    allow(CareRegulation::AppointmentSync).to receive(:call).and_wrap_original do |original, **kwargs|
      seen << kwargs.fetch(:appointment_request_id)
      original.call(**kwargs)
    end
    payloads.each { |name, payload| deliver_payload(name, payload) }
    expect(seen).to eq([ id ] * payloads.size)
    expect(request.reload).to have_attributes(status: "scheduled", scheduled_at: appointment.scheduled_at)
  end

  it "horário de outro pedido (sem linha) não chama a sincronização" do
    expect(CareRegulation::AppointmentSync).not_to receive(:call)
    deliver_payload("appointment.cancelled", appointment_id: SecureRandom.uuid, by: "citizen")
  end

  it "o mesmo evento entregue duas vezes processa uma vez (ProcessedEvent)" do
    appointment = schedule_regulated!(appointment_request, at: 2.days.from_now.change(hour: 9))
    deliver(event_for("appointment.scheduled", appointment_request_id: appointment_request.id))
    no_show!(appointment)
    event = event_for("appointment.no_show", appointment_request_id: appointment_request.id)
    expect(CareRegulation::AppointmentSync).to receive(:call).once.and_call_original
    2.times { deliver(event) }
    expect(ProcessedEvent.where(event_id: event.id, consumer: described_class.name).count).to eq(1)
    expect(request.reload).to have_attributes(status: "pending", misses: 1)
    expect(DomainEvent.where(name: "regulation_request.missed").count).to eq(1)
    expect(event.reload.published_at).to be_present
  end

  it "Review Focus 2: o no_show redespachado (event_id novo) depois da reautorização não conta segunda falta" do
    appointment = schedule_regulated!(appointment_request, at: 2.days.from_now.change(hour: 9))
    no_show!(appointment)
    event = event_for("appointment.no_show", appointment_request_id: appointment_request.id)
    deliver(event)
    reauthorize!(request.reload, offer: setup.fetch(:offer))
    deliver(event, event_id: SecureRandom.uuid)
    expect(request.reload).to have_attributes(status: "authorized", misses: 1)
    expect(DomainEvent.where(name: "regulation_request.missed").count).to eq(1)
  end

  it "Review Focus 2: scheduled chegando depois do checked_in não regride completed" do
    appointment = schedule_regulated!(appointment_request, at: 3.days.from_now.change(hour: 9))
    check_in_regulated!(appointment)
    deliver(event_for("appointment.checked_in", appointment_request_id: appointment_request.id))
    expect(request.reload.status).to eq("completed")
    deliver(event_for("appointment.scheduled", appointment_request_id: appointment_request.id))
    expect(request.reload.status).to eq("completed")
    expect(request.events.map(&:status)).to eq(%w[pending authorized completed])
  end

  it "todos os eventos reais entregues fora de ordem: o estado final é o do pedido de agendamento" do
    appointment = schedule_regulated!(appointment_request, at: 5.days.from_now.change(hour: 9))
    target = HealthUnit.create!(name: "UBS Recebe #{SecureRandom.hex(2)}", kind: "ubs")
    drain!(appointment_request.target_unit, to: target)
    fresh = AppointmentRequest.find_by!(moved_from_request_id: appointment_request.id)
    events = DomainEvent.where(name: described_class::EVENTS).to_a
    expect(events.map(&:name)).to include("appointment.scheduled", "appointment.moved", "appointment_request.moved",
                                          "appointment_request.closed", "appointment_request.created")
    events.shuffle(random: Random.new(26)).each { |event| deliver(event) }
    expect(request.reload).to have_attributes(status: "scheduled", appointment_request_id: fresh.id,
                                              scheduled_at: appointment.scheduled_at)
    expect(request.events.map(&:status)).to eq(%w[pending authorized scheduled])
  end

  it "evento de pedido de agendamento que não é regulated não toca nada" do
    other = triage_request!(regulation_patient!(exam_seq!).last, unit: create_unit("UBS Triagem #{SecureRandom.hex(2)}"))
    appointment = schedule_regulated!(other, at: 3.days.from_now.change(hour: 9))
    request
    events = RegulationRequestEvent.count
    versions = RegulationRequest.pluck(:id, :version)
    deliver(event_for("appointment.scheduled", appointment_request_id: other.id))
    deliver_payload("appointment.cancelled", appointment_id: appointment.id, by: "citizen")
    expect(RegulationRequestEvent.count).to eq(events)
    expect(RegulationRequest.pluck(:id, :version)).to match_array(versions)
  end

  it "rede de segurança no appointment_request.moved: pedido cancelado com o novo open → o novo vai a dismissed" do
    expect(CareRegulation::Decide.call(request: request.reload, decision: "cancel", reason: "Paciente operado em outro serviço",
                                       version: request.version, by: regulation_regulator!)).to be_ok
    target = HealthUnit.create!(name: "UBS Recebe #{SecureRandom.hex(2)}", kind: "ubs")
    orphan = AppointmentRequest.create!(kind: "regulated", origin_regulation_request_id: request.id, citizen_id: appointment_request.citizen_id,
                                        origin_unit_id: appointment_request.origin_unit_id, target_unit: target,
                                        moved_from_request: appointment_request, created_at: appointment_request.created_at,
                                        appointment_type_key: appointment_request.appointment_type_key,
                                        priority: appointment_request.priority, due_on: appointment_request.due_on)
    deliver_payload("appointment_request.moved", from_request_id: appointment_request.id, to_request_id: orphan.id,
                                                 from_unit_id: appointment_request.target_unit_id, to_unit_id: target.id)
    expect(orphan.reload).to have_attributes(status: "closed", closed_reason: "dismissed",
                                             dismiss_reason: CareRegulation::Catalog::SYNC_NOTES[:cancelled])
    expect(request.reload.status).to eq("cancelled")
  end

  it "não atribui Current.city: a cidade do chamador volta intacta" do
    city = Current.city
    deliver_payload("appointment_request.created", appointment_request_id: appointment_request.id)
    expect(Current.city).to eq(city)
  end
end
