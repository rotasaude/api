require "rails_helper"

RSpec.describe DomainEvents do
  it "exige cidade para publicar" do
    expect { DomainEvents.publish("foo.bar", x: 1) }.to raise_error(DomainEvents::CityMissing)
  end

  # Fix round 1 (M2): the old title implied publish SELECTS the city from
  # Current.city — it doesn't. publish writes DomainEvent on whatever
  # connection happens to be current (Current.city only supplies the
  # city_slug used for the CityMissing guard and the enqueued payload below).
  # The example proves the write lands on the current connection and not on
  # another city's, not that Current.city drives which connection is used.
  it "grava o evento na conexão corrente (a cidade aberta pelo harness), não em outra" do
    Current.city = TEST_CITY_A

    event_id = DomainEvents.publish("foo.bar", x: 1)

    row = DomainEvent.find(event_id)
    expect(row.payload).to eq("x" => 1)
    expect(CityConnection.with(TEST_CITY_B) { DomainEvent.exists?(event_id) }).to be(false)
  end

  it "enfileira subscriber com kwargs (event_id, event_name, city_slug, payload)" do
    Current.city = TEST_CITY_A
    subscriber = Class.new(ApplicationJob) { def perform(**); end }
    stub_const("FakeSub", subscriber)
    DomainEvents.bind("foo.bar", to: FakeSub)

    expect {
      DomainEvents.publish("foo.bar", x: 1)
    }.to have_enqueued_job(FakeSub).with(hash_including(
      event_name: "foo.bar",
      city_slug: TEST_CITY_A.slug,
      payload: { "x" => 1 }
    ))
  ensure
    DomainEvents.registry["foo.bar"].clear
  end
end
