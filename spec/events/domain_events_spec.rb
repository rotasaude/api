require "rails_helper"

RSpec.describe DomainEvents do
  it "exige cidade para publicar" do
    Current.set(city: nil) do
      expect { DomainEvents.publish("foo.bar", x: 1) }.to raise_error(DomainEvents::CityMissing)
    end
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

  # F-07.2 (ADR-0004/0014): o evento comita junto com a escrita de domínio.
  # Rollback da transação da cidade leva o DomainEvent e o subscriber juntos —
  # nem auditoria de algo que não aconteceu, nem job órfão na fila.
  describe "atomicidade com a transação da cidade" do
    include ActiveJob::TestHelper

    it "some com o rollback: nenhum evento gravado, nenhum subscriber enfileirado" do
      Current.city = TEST_CITY_A
      stub_const("FakeSub", Class.new(ApplicationJob) { def perform(**); end })
      DomainEvents.bind("foo.rolled_back", to: FakeSub)
      event_id = nil

      ApplicationRecord.transaction do
        event_id = DomainEvents.publish("foo.rolled_back", x: 1)
        expect(DomainEvent.exists?(event_id)).to be(true)
        raise ActiveRecord::Rollback
      end

      expect(DomainEvent.exists?(event_id)).to be(false)
      expect(enqueued_jobs.count { |j| j["job_class"] == "FakeSub" }).to eq(0)
    ensure
      DomainEvents.registry["foo.rolled_back"].clear
    end

    it "comita com a transação: evento gravado e subscriber enfileirado depois do COMMIT" do
      Current.city = TEST_CITY_A
      stub_const("FakeSub", Class.new(ApplicationJob) { def perform(**); end })
      DomainEvents.bind("foo.committed", to: FakeSub)
      event_id = nil

      ApplicationRecord.transaction { event_id = DomainEvents.publish("foo.committed", x: 1) }

      expect(DomainEvent.exists?(event_id)).to be(true)
      expect(enqueued_jobs.count { |j| j["job_class"] == "FakeSub" }).to eq(1)
    ensure
      DomainEvents.registry["foo.committed"].clear
    end
  end

  describe ".redispatch" do
    it "exige cidade para redespachar" do
      event = DomainEvent.new(id: SecureRandom.uuid, name: "foo.bar", payload: {})
      Current.set(city: nil) do
        expect { DomainEvents.redispatch(event) }.to raise_error(DomainEvents::CityMissing)
      end
    end

    it "reenfileira os subscribers ligados a event.name com os mesmos kwargs que publish usaria" do
      Current.city = TEST_CITY_A
      subscriber = Class.new(ApplicationJob) { def perform(**); end }
      stub_const("FakeSub", subscriber)
      DomainEvents.bind("foo.bar", to: FakeSub)

      event = DomainEvent.create!(id: SecureRandom.uuid, name: "foo.bar", payload: { "x" => 1 },
                                   occurred_at: 10.minutes.ago)

      expect {
        DomainEvents.redispatch(event)
      }.to have_enqueued_job(FakeSub).with(hash_including(
        event_id: event.id,
        event_name: "foo.bar",
        city_slug: TEST_CITY_A.slug,
        payload: { "x" => 1 }
      ))
    ensure
      DomainEvents.registry["foo.bar"].clear
    end
  end
end
