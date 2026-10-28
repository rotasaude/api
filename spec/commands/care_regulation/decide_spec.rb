require "rails_helper"

# Módulo 26a, Task 9 (ADR 0044; contrato §4, §13 G1, G7; plano do api, Desvio
# 9): devolver, negar e cancelar um pedido de regulação. Motivo em REASON
# (10–500), cifrado no andamento; cancelar devolve a cota da autorização
# vigente e, na rede própria, encerra o pedido de agendamento ainda `open`.
RSpec.describe CareRegulation::Decide do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.zone.local(2026, 10, 28, 10, 0) }

  before do
    travel_to now
    regulation_city!
  end

  let(:regulator) { care_regulator! }
  let(:offer) { offer!(provider: external_provider!, quantity: 1) }
  let(:specialist_unit) { create_unit("Centro de Especialidades #{SecureRandom.hex(2)}") }
  let(:own_offer) { offer!(provider: own_provider!(specialist_unit)) }
  let(:reason) { "Faltam os exames prévios do pedido" }

  def aged!(days, color = "yellow", **over)
    travel_to(now.change(hour: 12) - days.days)
    regulation_request!(suggested_color: color, **over)
  ensure
    travel_to now
  end

  def decide(request, decision, reason: self.reason, version: request.version)
    described_class.call(request: request, decision: decision, reason: reason, version: version, by: regulator)
  end

  def authorize!(request, offer:)
    result = CareRegulation::Authorize.call(request: request, offer_id: offer.id, version: request.version, by: regulator)
    raise "autorização recusada: #{result.reason}" if result.failure?

    request.reload
  end

  def used(offer) = CareRegulation::Quota.used([ offer.id ]).fetch(offer.id)

  def raw_reason(event)
    ApplicationRecord.connection.select_value(
      ApplicationRecord.sanitize_sql([ "SELECT reason FROM regulation_request_events WHERE id = ?", event.id ])
    )
  end

  it "devolve pending → returned com o motivo no andamento, cifrado (a coluna crua não tem o texto), evento só com ids" do
    request = aged!(3)
    result = decide(request, "return")
    expect(result).to be_ok
    expect(request.reload).to have_attributes(status: "returned", version: 3)
    event = request.events.last
    expect(event).to have_attributes(status: "returned", by_user_id: regulator.id, reason: reason)
    expect(raw_reason(event)).to be_present
    expect(raw_reason(event)).not_to include("exames")
    expect(DomainEvent.where(name: "regulation_request.returned").map(&:payload))
      .to eq([ { "regulation_request_id" => request.id, "user_id" => regulator.id } ])
  end

  it "devolver só de pending: returned ou authorized → invalid_transition" do
    request = aged!(3)
    expect(decide(request, "return")).to be_ok
    expect(decide(request.reload, "return").reason).to eq(:invalid_transition)
    authorized = authorize!(aged!(4), offer: offer!(provider: external_provider!))
    expect(decide(authorized, "return").reason).to eq(:invalid_transition)
  end

  it "nega returned → denied; negar authorized → invalid_transition e nada muda" do
    request = aged!(3)
    expect(decide(request, "return")).to be_ok
    travel_to(now + 1.minute) # o andamento é ordenado por created_at: relógio fixo empataria
    expect(decide(request.reload, "deny", reason: "Pedido fora do protocolo municipal")).to be_ok
    expect(request.reload).to have_attributes(status: "denied", version: 4)
    expect(request.events.map(&:status)).to eq(%w[pending returned denied])

    authorized = authorize!(aged!(4), offer: offer)
    expect(decide(authorized, "deny").reason).to eq(:invalid_transition)
    expect(authorized.reload).to have_attributes(status: "authorized", version: 3)
  end

  it "nega pending direto" do
    request = aged!(3)
    expect(decide(request, "deny")).to be_ok
    expect(request.reload.status).to eq("denied")
  end

  it "cancelar authorized de oferta externa libera a cota com release_reason cancelled; outra autorização na mesma oferta passa" do
    request = authorize!(aged!(3), offer: offer)
    expect(used(offer)).to eq(1)
    expect(decide(request, "cancel")).to be_ok
    expect(request.reload).to have_attributes(status: "cancelled", version: 4)
    expect(request.authorizations.sole).to have_attributes(released_at: now, release_reason: "cancelled")
    expect(used(offer)).to eq(0)
    expect(DomainEvent.where(name: "regulation_request.cancelled").map(&:payload))
      .to eq([ { "regulation_request_id" => request.id, "user_id" => regulator.id } ])

    other = aged!(2)
    expect(CareRegulation::Authorize.call(request: other, offer_id: offer.id, version: other.version, by: regulator)).to be_ok
    expect(used(offer)).to eq(1)
  end

  it "cancelar authorized própria com o pedido de agendamento open encerra-o como dismissed com a nota SYNC_NOTES[:cancelled]" do
    request = authorize!(aged!(3), offer: own_offer)
    appointment = AppointmentRequest.find(request.appointment_request_id)
    expect(appointment.status).to eq("open")
    expect(decide(request, "cancel")).to be_ok
    expect(appointment.reload).to have_attributes(status: "closed", closed_reason: "dismissed", closed_by_user_id: regulator.id,
                                                  dismiss_reason: CareRegulation::Catalog::SYNC_NOTES[:cancelled])
    expect(request.reload.status).to eq("cancelled")
    expect(used(own_offer)).to eq(0)
  end

  it "com horário marcado (Appointments::Schedule) → appointment_scheduled e nada muda" do
    request = authorize!(aged!(3), offer: own_offer)
    appointment = AppointmentRequest.find(request.appointment_request_id)
    scheduled = Appointments::Schedule.call(request: appointment, scheduled_at: (now + 5.days).change(hour: 9).iso8601,
                                            health_unit_id: specialist_unit.id, by: reception!)
    expect(scheduled).to be_ok
    expect(decide(request, "cancel").reason).to eq(:appointment_scheduled)
    expect(request.reload).to have_attributes(status: "authorized", version: 3)
    expect(appointment.reload.status).to eq("scheduled")
    expect(request.authorizations.sole.released_at).to be_nil
    expect(used(own_offer)).to eq(1)
    expect(DomainEvent.where(name: "regulation_request.cancelled")).to be_empty
  end

  it "cancela pending, returned e external (sem autorização: nada a liberar)" do
    pending = aged!(3)
    returned = aged!(3)
    expect(decide(returned, "return")).to be_ok
    external = aged!(3, status: "external")
    [ pending, returned.reload, external ].each do |request|
      expect(decide(request, "cancel")).to be_ok
      expect(request.reload.status).to eq("cancelled")
    end
    expect(RegulationAuthorization.count).to eq(0)
  end

  it "cancelado, negado ou devolvido-e-negado não cancela de novo: invalid_transition" do
    request = aged!(3)
    expect(decide(request, "cancel")).to be_ok
    expect(decide(request.reload, "cancel").reason).to eq(:invalid_transition)
    expect(decide(request, "deny").reason).to eq(:invalid_transition)
  end

  it "versão velha → stale_version e nada muda" do
    request = aged!(3)
    expect(decide(request, "return", version: 1).reason).to eq(:stale_version)
    expect(request.reload).to have_attributes(status: "pending", version: 2)
  end

  it "motivo de 9 caracteres → invalid_request (path reason); 501 também; espaços nas pontas não contam; versão não inteira" do
    request = aged!(3)
    expect(decide(request, "return", reason: "123456789")).to have_attributes(reason: :invalid_request, details: { path: "reason" })
    expect(decide(request, "return", reason: "x" * 501).details).to eq(path: "reason")
    expect(decide(request, "return", reason: "   123456789   ").details).to eq(path: "reason")
    expect(decide(request, "return", reason: nil).details).to eq(path: "reason")
    expect(decide(request, "return", version: "2").details).to eq(path: "version")
    expect(request.reload).to have_attributes(status: "pending", version: 2)
    expect(decide(request, "return", reason: "  #{'x' * 10}  ")).to be_ok
    expect(request.reload.events.last.reason).to eq("x" * 10)
  end

  it "decisão desconhecida é erro de programação" do
    expect { decide(aged!(3), "authorize") }.to raise_error(ArgumentError)
  end
end
