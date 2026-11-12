require "rails_helper"

# Módulo 33, Task 9, fix round 1: o dia do teto é o da hora em que o envio
# PEGA a trava de ombudsman_settings, não o da chegada. Um envio que chega às
# 23:59:59 e só pega a trava depois da meia-noite conta, grava e marca o dia
# novo — e o evento (occurred_at) cai no mesmo dia da marca. A espera da trava
# é simulada avançando o relógio dentro de OmbudsmanSetting.lock.
RSpec.describe "Ombudsman::RegisterAnonymous — meia-noite durante a espera da trava" do
  include ActiveSupport::Testing::TimeHelpers

  let(:text) { "Denúncia que esperou a trava passar da meia-noite." }
  let(:day1) { Date.new(2026, 11, 11) }
  let(:day2) { Date.new(2026, 11, 12) }

  before do
    ombudsman_city!(anonymous: true)
    OmbudsmanSetting.current.update!(anonymous_daily_cap: 1)
    raw_manifestation!(kind: "report", identification_mode: "anonymous", received_at: Time.zone.local(2026, 11, 11, 23, 0))
    travel_to Time.zone.local(2026, 11, 11, 23, 59, 59)
    allow(OmbudsmanSetting).to receive(:lock).and_wrap_original do |original, *args|
      travel_to Time.zone.local(2026, 11, 12, 0, 0, 1)
      original.call(*args)
    end
  end
  after do
    travel_back
    Current.reset
  end

  def call = Ombudsman::RegisterAnonymous.call(body: text, health_unit_id: nil)

  it "conta o dia em que pegou a trava: o teto do dia 1 não vale para o dia 2" do
    result = call

    expect(result).to be_ok
    expect(result.payload.fetch(:manifestation).received_at).to eq(Time.zone.local(2026, 11, 12, 0, 0, 1))
    expect(OmbudsmanDailyRun.where(kind: "anonymous_cap")).to be_empty
  end

  it "no teto do dia 2: a marca e o evento caem no dia 2, e o e-mail vai para o dia 2" do
    raw_manifestation!(kind: "report", identification_mode: "anonymous", received_at: Time.zone.local(2026, 11, 12, 0, 0, 0))

    expect(call.reason).to eq(:daily_cap_reached)

    expect(OmbudsmanDailyRun.where(kind: "anonymous_cap").pluck(:run_on)).to eq([ day2 ])
    event = DomainEvent.where(name: "ombudsman.anonymous_cap_reached").sole
    expect(event.occurred_at.in_time_zone.to_date).to eq(day2)
    expect { Ombudsman::CapAlertJob.perform_now(event_id: event.id, event_name: event.name, city_slug: Current.city.slug, payload: {}) }
      .to have_enqueued_job(Ombudsman::MailJob).with(city_slug: Current.city.slug, kind: "anonymous_cap", ref: day2.iso8601)
  end
end
