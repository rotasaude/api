require "rails_helper"

# Módulo 26a, G15.2 (contrato §13 G15): o desfecho (completed/missed) só vale a
# partir do DIA do agendamento, no fuso da cidade. Antes do dia →
# fail(:outcome_before_schedule), conferido sob a trava depois de
# stale_version e invalid_transition; nada muda e nenhum evento sai.
RSpec.describe CareRegulation::RecordOutcome do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.zone.local(2026, 10, 6, 10, 0) }
  let(:appointment) { Time.zone.local(2026, 10, 16, 14, 30) }

  before do
    travel_to now
    regulation_city!
    tick_regulation_events!
  end

  let(:regulator) { regulation_regulator! }

  def scheduled!(at: appointment)
    request = regulation_request!(status: "external")
    result = CareRegulation::ScheduleExternal.call(request: request, at: at.iso8601, place: "Hospital Regional", notes: nil,
                                                   version: request.version, by: regulator)
    raise "agendamento recusado: #{result.reason}" if result.failure?

    request.reload
  end

  def record(request, result: "completed", version: request.version) = described_class.call(request: request, result: result, version: version, by: regulator)
  def outcome_events = DomainEvent.where(name: %w[regulation_request.completed regulation_request.missed]).count

  %w[completed missed].each do |result|
    it "#{result} antes do dia do agendamento → outcome_before_schedule, sem evento nem mudança" do
      request = scheduled!
      before_state = request.slice(:status, :version, :misses, :scheduled_at)
      events = request.events.count

      travel_to appointment.beginning_of_day - 1.second
      outcome = record(request, result: result)

      expect(outcome).to be_failure
      expect(outcome.reason).to eq(:outcome_before_schedule)
      expect(request.reload.slice(:status, :version, :misses, :scheduled_at)).to eq(before_state)
      expect(request.events.count).to eq(events)
      expect(outcome_events).to eq(0)
    end
  end

  it "no próprio dia do agendamento, mesmo antes da hora, é aceito" do
    request = scheduled!
    travel_to appointment.beginning_of_day
    expect(record(request)).to be_ok
    expect(request.reload.status).to eq("completed")
  end

  it "depois do dia do agendamento é aceito" do
    request = scheduled!
    travel_to appointment + 3.days
    expect(record(request, result: "missed")).to be_ok
    expect(request.reload.misses).to eq(1)
  end

  it "o dia é o da cidade: agendamento às 23h30 locais vale no mesmo dia local, mesmo já sendo o dia seguinte em UTC" do
    late = Time.zone.local(2026, 10, 16, 23, 30)
    request = scheduled!(at: late)
    travel_to Time.zone.local(2026, 10, 16, 0, 5)
    expect(record(request)).to be_ok
  end

  it "stale_version e invalid_transition vêm antes: fora de scheduled ou com versão velha, a recusa é a deles" do
    request = scheduled!
    expect(record(request, version: request.version - 1).reason).to eq(:stale_version)

    other = regulation_request!(status: "external")
    expect(record(other).reason).to eq(:invalid_transition)
  end
end
