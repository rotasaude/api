require "rails_helper"

RSpec.describe DomainEvents do
  let(:muni) { create(:municipality) }

  it "exige tenant para publicar" do
    expect { DomainEvents.publish("foo.bar", x: 1) }.to raise_error(DomainEvents::TenantMissing)
  end

  it "carimba municipality_id na linha de domain_events" do
    ApplicationRecord.transaction do
      Current.municipality_id = muni.id
      ApplicationRecord.connection.execute(
        ApplicationRecord.sanitize_sql(["SET LOCAL app.municipality_id = ?", muni.id])
      )
      event_id = DomainEvents.publish("foo.bar", x: 1)
      row = DomainEvent.find(event_id)
      expect(row.municipality_id).to eq(muni.id)
      expect(row.payload).to eq("x" => 1)
    end
  end

  it "enfileira subscriber com kwargs (event_id, event_name, municipality_id, payload)" do
    subscriber = Class.new(ApplicationJob) { def perform(**); end }
    stub_const("FakeSub", subscriber)
    DomainEvents.bind("foo.bar", to: FakeSub)

    ApplicationRecord.transaction do
      Current.municipality_id = muni.id
      ApplicationRecord.connection.execute(
        ApplicationRecord.sanitize_sql(["SET LOCAL app.municipality_id = ?", muni.id])
      )
      expect {
        DomainEvents.publish("foo.bar", x: 1)
      }.to have_enqueued_job(FakeSub).with(hash_including(
        event_name: "foo.bar",
        municipality_id: muni.id,
        payload: { "x" => 1 }
      ))
    end
  ensure
    DomainEvents.registry["foo.bar"].clear
  end
end
