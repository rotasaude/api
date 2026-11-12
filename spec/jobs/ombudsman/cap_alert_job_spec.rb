require "rails_helper"

# Módulo 33, Task 9 (ADR 0051; contrato §4; §16 Q21): o consumidor de
# ombudsman.anonymous_cap_reached (payload {}) só enfileira o e-mail do teto,
# com o dia local em que o evento aconteceu; uma vez por evento.
RSpec.describe "Ombudsman::CapAlertJob" do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  before { ombudsman_city!(anonymous: true) }
  after do
    travel_back
    Current.reset
  end

  def consume!(event)
    Ombudsman::CapAlertJob.perform_now(event_id: event.id, event_name: event.name, city_slug: Current.city.slug, payload: event.payload)
  end

  it "sem marca: o dia do evento, mesmo consumido depois da meia-noite; só uma vez por evento" do
    travel_to Time.zone.local(2026, 11, 11, 23, 59)
    DomainEvents.publish("ombudsman.anonymous_cap_reached")
    event = DomainEvent.where(name: "ombudsman.anonymous_cap_reached").sole
    expect(event.payload).to eq({})
    clear_enqueued_jobs

    travel_to Time.zone.local(2026, 11, 12, 0, 1)
    consume!(event)
    consume!(event)

    assert_enqueued_jobs 1, only: Ombudsman::MailJob
    assert_enqueued_with(job: Ombudsman::MailJob, args: [ { city_slug: Current.city.slug, kind: "anonymous_cap", ref: "2026-11-11" } ])
  end

  # Fix round 1: o dia é o da marca gravada na mesma transação do evento (a
  # mais recente até o occurred_at), não o do relógio do publish — a marca do
  # dia 1 gravada às 23:59:59.9 e o evento às 00:00:00.1 mandam o e-mail do
  # dia 1. A marca de um dia posterior ao evento não conta.
  it "toma o dia da marca do teto, mesmo com o evento já no dia seguinte" do
    travel_to Time.zone.local(2026, 11, 11, 23, 59, 59) + 0.9
    OmbudsmanDailyRun.create!(run_on: Date.new(2026, 11, 11), kind: "anonymous_cap", created_at: Time.current)
    travel_to Time.zone.local(2026, 11, 12, 0, 0, 0) + 0.1
    DomainEvents.publish("ombudsman.anonymous_cap_reached")
    event = DomainEvent.where(name: "ombudsman.anonymous_cap_reached").sole
    travel_to Time.zone.local(2026, 11, 13, 9, 0)
    OmbudsmanDailyRun.create!(run_on: Date.new(2026, 11, 13), kind: "anonymous_cap", created_at: Time.current)
    clear_enqueued_jobs

    consume!(event)

    assert_enqueued_with(job: Ombudsman::MailJob, args: [ { city_slug: Current.city.slug, kind: "anonymous_cap", ref: "2026-11-11" } ])
  end
end
