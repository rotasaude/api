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

  it "enfileira um MailJob do dia do evento, mesmo consumido depois da meia-noite; só uma vez por evento" do
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
end
