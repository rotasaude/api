require "rails_helper"

# Módulo 25, Task 13 (ADR 0043): o consumidor de disease_notification.created
# só enfileira o e-mail; só a imediata, só com o módulo ligado.
RSpec.describe Surveillance::AlertJob do
  include ActiveJob::TestHelper

  before { surveillance_city! }
  after { Current.reset }

  def consume!(event)
    described_class.perform_now(event_id: event.id, event_name: event.name, city_slug: Current.city.slug, payload: event.payload)
  end

  def created_event = DomainEvent.where(name: "disease_notification.created").order(:occurred_at, :created_at).last

  it "imediata: enfileira um MailJob com o id; só uma vez por evento" do
    n = notification!(patient: surveillance_patient!(1), disease_code: "sarampo")
    expect(created_event.payload).to eq("notification_id" => n.id, "immediate" => true)
    clear_enqueued_jobs

    consume!(created_event)
    consume!(created_event)

    assert_enqueued_jobs 1, only: Surveillance::MailJob
    assert_enqueued_with(job: Surveillance::MailJob, args: [ { city_slug: Current.city.slug, kind: "immediate", ref: n.id } ])
  end

  it "semanal não enfileira nada" do
    notification!(patient: surveillance_patient!(2), disease_code: "dengue")
    expect(created_event.payload["immediate"]).to be(false)
    clear_enqueued_jobs

    consume!(created_event)

    assert_no_enqueued_jobs only: Surveillance::MailJob
  end

  it "com o interruptor desligado não enfileira" do
    notification!(patient: surveillance_patient!(3), disease_code: "sarampo")
    clear_enqueued_jobs
    Platform::Features.set!(city: Current.city, key: "surveillance", enabled: false, maintainer: ledi_maintainer!)

    consume!(created_event)

    assert_no_enqueued_jobs only: Surveillance::MailJob
  end
end
