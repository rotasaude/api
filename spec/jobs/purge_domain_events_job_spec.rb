require "rails_helper"
require Rails.root.join("spec/support/admin_rls")

RSpec.describe PurgeDomainEventsJob, type: :job do
  self.use_transactional_tests = false

  before { clean_admin_tables }
  after  { clean_admin_tables }

  # Cria um domain_event com occurred_at explícito (default seria Time.current).
  def make_event(muni_id, occurred_at:, name: "triage.completed")
    as_admin do
      ev = DomainEvent.create!(name: name, payload: {}, municipality_id: muni_id, occurred_at: occurred_at)
      ev.id
    end
  end

  let(:muni_id) do
    as_admin { Municipality.create!(name: "Purge City", slug: "purge-city", ibge_code: "3500070").id }
  end

  it "deletes events older than the 12-month window and keeps recent ones" do
    old_id    = make_event(muni_id, occurred_at: 13.months.ago)
    recent_id = make_event(muni_id, occurred_at: 1.month.ago)

    described_class.new.perform(older_than_months: 12)

    as_admin do
      expect(DomainEvent.exists?(old_id)).to be(false)
      expect(DomainEvent.exists?(recent_id)).to be(true)
    end
  end

  it "keeps an event just inside the window (strict < cutoff)" do
    just_inside_id = make_event(muni_id, occurred_at: 11.months.ago)
    described_class.new.perform(older_than_months: 12)
    as_admin { expect(DomainEvent.exists?(just_inside_id)).to be(true) }
  end

  it "honors a custom window" do
    two_months_id = make_event(muni_id, occurred_at: 2.months.ago)
    one_week_id    = make_event(muni_id, occurred_at: 1.week.ago)
    described_class.new.perform(older_than_months: 1)
    as_admin do
      expect(DomainEvent.exists?(two_months_id)).to be(false)
      expect(DomainEvent.exists?(one_week_id)).to be(true)
    end
  end
end
