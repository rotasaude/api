require "rails_helper"

# Suspender tira a cidade do ar sem apagar nada (spec banco-por-cidade §4). O 403
# no host está em spec/requests/city_resolution_spec.rb.
RSpec.describe "CityLifecycle::Suspend and CityLifecycle::Resume" do
  let(:city) { create(:city, status: "active", database_url: city_database_url("rota_saude_test_city_b")) }

  def events(name) = PlatformEvent.where(name: name).where("payload->>'city_id' = ?", city.id)

  it "suspends an active city, drops its pool in this process and audits" do
    CityConnection.ensure_pool(city)

    result = CityLifecycle::Suspend.call(city: city)

    expect(result.ok?).to be(true)
    expect(city.reload.status).to eq("suspended")
    expect(CityConnection.registered?(city.shard)).to be(false)
    expect(events("city.suspended").pluck(:payload)).to eq([ { "city_id" => city.id } ])
  end

  it "refuses to suspend a city that is not active, writing nothing" do
    city.update!(status: "provisioning")

    result = nil
    expect { result = CityLifecycle::Suspend.call(city: city) }.not_to change(PlatformEvent, :count)
    expect(result.reason).to eq(:invalid_status)
    expect(city.reload.status).to eq("provisioning")
  end

  it "resumes a suspended city and audits, and refuses a city that is not suspended" do
    city.update!(status: "suspended")

    expect(CityLifecycle::Resume.call(city: city).ok?).to be(true)
    expect(city.reload.status).to eq("active")
    expect(events("city.resumed").count).to eq(1)

    expect(CityLifecycle::Resume.call(city: city).reason).to eq(:invalid_status)
  end

  it "refuses to suspend when the row stopped being active after the city was loaded, writing nothing" do
    city
    City.where(id: city.id).update_all(status: "suspended")

    result = nil
    expect { result = CityLifecycle::Suspend.call(city: city) }.not_to change(PlatformEvent, :count)
    expect(result.reason).to eq(:invalid_status)
    expect(result.message).to eq("cidade #{city.slug} mudou de status durante a operação")
    expect(city.reload.status).to eq("suspended")
  end

  it "refuses to resume when the row stopped being suspended after the city was loaded, writing nothing" do
    city.update!(status: "suspended")
    City.where(id: city.id).update_all(status: "archived")

    result = nil
    expect { result = CityLifecycle::Resume.call(city: city) }.not_to change(PlatformEvent, :count)
    expect(result.reason).to eq(:invalid_status)
    expect(result.message).to eq("cidade #{city.slug} mudou de status durante a operação")
    expect(city.reload.status).to eq("archived")
  end
end
