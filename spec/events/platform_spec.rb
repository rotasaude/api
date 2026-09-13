require "rails_helper"

RSpec.describe Platform do
  it "grava PlatformEvent na plataforma, não DomainEvent na cidade" do
    Platform.audit("user.logged_in", user_id: SecureRandom.uuid)

    ev = PlatformEvent.order(occurred_at: :desc).first
    expect(ev.name).to eq("user.logged_in")
  end

  it "linha platform-scope não aparece nos domain_events de nenhuma cidade" do
    Platform.audit("user.logged_in", user_id: SecureRandom.uuid)

    expect(DomainEvent.where(name: "user.logged_in").count).to eq(0)
    expect(CityConnection.with(TEST_CITY_B) { DomainEvent.where(name: "user.logged_in").count }).to eq(0)
  end
end
