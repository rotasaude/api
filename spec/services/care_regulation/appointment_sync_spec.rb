require "rails_helper"

# Módulo 26a, Task 10 (ADR 0044; contrato §7, §13 G1, G6; plano do api,
# Desvios 7 e 8, Review Focus 2 e 3): a rede própria acompanhada pelo estado
# ATUAL do pedido de agendamento do 17. Pedido autorizado em oferta própria
# pela Task 8; horário pelo caminho real (Appointments::Schedule em dia sem
# turno), check-in por Attendances::CheckIn, falta e expiração por
# Appointments::Lapse, esvaziamento por HealthUnits::Drain.
RSpec.describe CareRegulation::AppointmentSync do
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

  def sync! = described_class.call(appointment_request_id: request.reload.appointment_request_id)
  def used = CareRegulation::Quota.used([ setup.fetch(:offer).id ]).values.sum
  def regulation_events(name) = DomainEvent.where(name: "regulation_request.#{name}").map(&:payload)

  it "horário marcado → scheduled com data e local; atendimento → completed; redespacho não regride" do
    appointment = schedule_regulated!(appointment_request, at: 3.days.from_now.change(hour: 9))
    expect(sync!).to eq("scheduled")
    expect(request.reload).to have_attributes(status: "scheduled", scheduled_at: appointment.scheduled_at, schedule_notes: nil)
    expect(request.schedule_place).to include(appointment_request.target_unit.name)
    expect(sync!).to eq(:unchanged)
    check_in_regulated!(appointment)
    expect(sync!).to eq("completed")
    expect(sync!).to eq(:unchanged)
    expect(request.reload).to have_attributes(status: "completed", appointment_request_id: appointment_request.id)
    expect(request.events.map(&:status)).to eq(%w[pending authorized scheduled completed])
    expect(request.events.last(2).map(&:by_user_id)).to eq([ nil, nil ])
    expect(used).to eq(1) # atendimento não libera
    expect(CareRegulation::Json.request(request)[:outcome]).to eq("completed")
    expect(regulation_events("completed")).to eq([ { "regulation_request_id" => request.id, "user_id" => nil } ])
  end

  it "Review Focus 2: falta volta à fila uma vez; o no_show redespachado depois da reautorização não conta de novo" do
    appointment = schedule_regulated!(appointment_request, at: 2.days.from_now.change(hour: 9))
    sync!
    no_show!(appointment)
    expect(sync!).to eq("pending")
    expect(request.reload).to have_attributes(misses: 1, appointment_request_id: nil, scheduled_at: nil, schedule_place: nil,
                                              due_on: setup.fetch(:regulation_request).due_on,
                                              requested_at: setup.fetch(:regulation_request).requested_at)
    expect(appointment_request.reload).to have_attributes(status: "closed", closed_reason: "dismissed", closed_by_user_id: nil,
                                                          dismiss_reason: CareRegulation::Catalog::SYNC_NOTES[:missed])
    expect(used).to eq(1)
    expect(request.events.map(&:status).last(2)).to eq(%w[missed pending])
    expect(regulation_events("missed")).to eq([ { "regulation_request_id" => request.id, "user_id" => nil } ])
    expect(CareRegulation::Json.request(request)[:authorization]).to be_nil

    # Redespacho antes da reautorização: o pedido de agendamento já não é dele.
    expect(described_class.call(appointment_request_id: appointment_request.id)).to eq(:ignored)
    reauthorize!(request.reload, offer: setup.fetch(:offer))
    expect(described_class.call(appointment_request_id: appointment_request.id)).to eq(:ignored)
    expect(request.reload).to have_attributes(status: "authorized", misses: 1)
    expect(regulation_events("missed").size).to eq(1)
    expect(used).to eq(2)
    fresh = request.authorizations.last
    expect(CareRegulation::Json.request(request)[:authorization]).to include(offer_id: setup.fetch(:offer).id, at: fresh.created_at.iso8601)
  end

  it "segunda falta encerra (closed, outcome missed); a cota das duas autorizações segue usada" do
    2.times do |i|
      ar = AppointmentRequest.find(request.reload.appointment_request_id)
      no_show!(schedule_regulated!(ar, at: (2 + i).days.from_now.change(hour: 9)))
      described_class.call(appointment_request_id: ar.id)
      reauthorize!(request.reload, offer: setup.fetch(:offer)) if i.zero?
    end
    expect(request.reload).to have_attributes(status: "closed", misses: 2, appointment_request_id: nil)
    expect(request.events.map(&:status).last(2)).to eq(%w[missed closed])
    expect(CareRegulation::Json.request(request)[:outcome]).to eq("missed")
    expect(CareRegulation::Json.request(request)[:authorization]).to include(offer_id: setup.fetch(:offer).id)
    expect(AppointmentRequest.live_requests.where(origin_regulation_request_id: request.id)).to be_empty
    expect(used).to eq(2)
  end

  it "horário expirado (sem confirmação) volta a authorized sem contar falta" do
    appointment = schedule_regulated!(appointment_request, at: 5.days.from_now.change(hour: 9))
    sync!
    expire!(appointment)
    expect(sync!).to eq("authorized")
    expect(request.reload).to have_attributes(status: "authorized", misses: 0, scheduled_at: nil, schedule_place: nil,
                                              appointment_request_id: appointment_request.id)
    expect(appointment_request.reload.status).to eq("open")
    expect(regulation_events("missed")).to be_empty
    expect(used).to eq(1)
    expect(sync!).to eq(:unchanged)
  end

  it "cancelado pelo cidadão → cancelled com a cota liberada e sem autor" do
    appointment = schedule_regulated!(appointment_request, at: 5.days.from_now.change(hour: 9))
    expect(Appointments::CancelByCitizen.call(appointment: appointment, reason: "Não consigo ir nesse dia")).to be_ok
    at = Time.current
    expect(sync!).to eq("cancelled")
    expect(request.reload.events.last).to have_attributes(status: "cancelled", by_user_id: nil, reason: nil)
    expect(request.authorizations.sole).to have_attributes(release_reason: "citizen_cancelled", released_at: at)
    expect(used).to eq(0)
    expect(regulation_events("cancelled")).to eq([ { "regulation_request_id" => request.id, "user_id" => nil } ])
  end

  it "encerrado pela unidade (Dismiss fora de SYNC_NOTES) → cancelled com release_reason unit_dismissed" do
    expect(AppointmentRequests::Dismiss.call(request: appointment_request, reason: "Paciente mudou de município",
                                             health_unit_id: appointment_request.target_unit_id, by: reception!)).to be_ok
    expect(sync!).to eq("cancelled")
    expect(request.authorizations.sole.release_reason).to eq("unit_dismissed")
    expect(used).to eq(0)
  end

  it "Review Focus 3: unidade esvaziada pelo Drain — o pedido de regulação segue o pedido novo e continua scheduled" do
    appointment = schedule_regulated!(appointment_request, at: 5.days.from_now.change(hour: 9))
    sync!
    target = HealthUnit.create!(name: "UBS Recebe #{SecureRandom.hex(2)}", kind: "ubs")
    drain!(appointment_request.target_unit, to: target)
    fresh = AppointmentRequest.find_by!(moved_from_request_id: appointment_request.id)
    expect(fresh.origin_regulation_request_id).to eq(request.id)
    # O evento do pedido antigo (o horário movido) também leva ao novo.
    expect(described_class.call(appointment_request_id: appointment_request.id)).to eq("scheduled")
    expect(request.reload).to have_attributes(status: "scheduled", appointment_request_id: fresh.id,
                                              scheduled_at: appointment.scheduled_at)
    expect(request.schedule_place).to start_with(target.name)
    expect(described_class.call(appointment_request_id: fresh.id)).to eq(:unchanged)
    expect(used).to eq(1)
  end

  it "Drain de pedido sem horário: só o ponteiro segue o pedido novo (nada muda na situação)" do
    target = HealthUnit.create!(name: "UBS Recebe #{SecureRandom.hex(2)}", kind: "ubs")
    version = request.reload.version
    drain!(appointment_request.target_unit, to: target)
    fresh = AppointmentRequest.find_by!(moved_from_request_id: appointment_request.id)
    expect(described_class.call(appointment_request_id: fresh.id)).to eq(:unchanged)
    expect(request.reload).to have_attributes(status: "authorized", appointment_request_id: fresh.id, version: version)
  end

  it "falta seguida de Drain antes da sincronização: o pedido novo herda o no_show e a falta conta uma vez" do
    appointment = schedule_regulated!(appointment_request, at: 2.days.from_now.change(hour: 9))
    sync!
    no_show!(appointment)
    target = HealthUnit.create!(name: "UBS Recebe #{SecureRandom.hex(2)}", kind: "ubs")
    drain!(appointment_request.target_unit, to: target)
    fresh = AppointmentRequest.find_by!(moved_from_request_id: appointment_request.id)
    expect(described_class.call(appointment_request_id: appointment_request.id)).to eq("pending")
    expect(fresh.reload).to have_attributes(status: "closed", closed_reason: "dismissed",
                                            dismiss_reason: CareRegulation::Catalog::SYNC_NOTES[:missed])
    expect(described_class.call(appointment_request_id: fresh.id)).to eq(:ignored)
    expect(request.reload.misses).to eq(1)
  end

  it "rede de segurança (Cancelar × Drain): pedido cancelado com pedido de agendamento novo vivo → o novo vai a dismissed" do
    regulator = regulation_regulator!
    expect(CareRegulation::Decide.call(request: request.reload, decision: "cancel", reason: "Paciente operado em outro serviço",
                                       version: request.version, by: regulator)).to be_ok
    expect(appointment_request.reload.status).to eq("closed")
    # O estado que a corrida deixa: o Drain, sob a trava do pedido de
    # agendamento, criou a cópia viva ligada ao antigo antes de o cancelamento
    # ler o vivo (a cópia é a do HealthUnits::Drain.move).
    target = HealthUnit.create!(name: "UBS Recebe #{SecureRandom.hex(2)}", kind: "ubs")
    orphan = AppointmentRequest.create!(kind: "regulated", origin_regulation_request_id: request.id, citizen_id: appointment_request.citizen_id,
                                        origin_unit_id: appointment_request.origin_unit_id, target_unit: target,
                                        moved_from_request: appointment_request, created_at: appointment_request.created_at,
                                        appointment_type_key: appointment_request.appointment_type_key,
                                        priority: appointment_request.priority, due_on: appointment_request.due_on)
    released = request.authorizations.sole.released_at
    version = request.reload.version

    expect(described_class.call(appointment_request_id: orphan.id)).to eq(:unchanged)
    expect(orphan.reload).to have_attributes(status: "closed", closed_reason: "dismissed", closed_by_user_id: nil,
                                             dismiss_reason: CareRegulation::Catalog::SYNC_NOTES[:cancelled])
    expect(request.reload).to have_attributes(status: "cancelled", version: version)
    expect(request.authorizations.sole.released_at).to eq(released)
    expect(used).to eq(0)
  end

  it "ignora: pedido não regulated, pedido inexistente e pedido de regulação fora de authorized/scheduled sem cadeia" do
    other = triage_request!(regulation_patient!(exam_seq!).last, unit: create_unit("UBS Triagem #{SecureRandom.hex(2)}"))
    expect(described_class.call(appointment_request_id: other.id)).to eq(:ignored)
    expect(described_class.call(appointment_request_id: SecureRandom.uuid)).to eq(:ignored)
    expect(described_class.call(appointment_request_id: nil)).to eq(:ignored)
    expect(request.reload.status).to eq("authorized")
  end

  it "roda com o interruptor desligado (R16, G6)" do
    appointment = schedule_regulated!(appointment_request, at: 3.days.from_now.change(hour: 9))
    Platform::Features.set!(city: Current.city, key: "care_regulation", enabled: false, maintainer: ledi_maintainer!)
    expect(sync!).to eq("scheduled")
    expect(request.reload.scheduled_at).to eq(appointment.scheduled_at)
  end

  describe "local da rede própria" do
    it "nome e endereço da unidade (rua, número, complemento)" do
      unit = appointment_request.target_unit
      unit.update!(address_street: "Rua Engenheiro Rebouças", address_number: "1500", address_complement: "Bloco B")
      schedule_regulated!(appointment_request, at: 3.days.from_now.change(hour: 9))
      sync!
      expect(request.reload.schedule_place).to eq("#{unit.name} — Rua Engenheiro Rebouças, 1500, Bloco B")
    end

    it "sem endereço: só o nome" do
      schedule_regulated!(appointment_request, at: 3.days.from_now.change(hour: 9))
      sync!
      expect(request.reload.schedule_place).to eq(appointment_request.target_unit.name)
    end

    it "só o endereço é cortado em PLACE_MAX; o nome nunca" do
      unit = appointment_request.target_unit
      long_name = "Centro Municipal de Especialidades #{'Vila Hauer ' * 8}".strip
      street = "Avenida #{'Comendador Franco ' * 8}".strip
      unit.update!(name: long_name, address_street: street, address_number: "77")
      schedule_regulated!(appointment_request, at: 3.days.from_now.change(hour: 9))
      sync!
      place = request.reload.schedule_place
      expect(place.length).to be <= CareRegulation::Catalog::PLACE_MAX
      expect(place).to start_with("#{long_name} — Avenida Comendador")
      expect(street.length + long_name.length).to be > CareRegulation::Catalog::PLACE_MAX
    end
  end
end
