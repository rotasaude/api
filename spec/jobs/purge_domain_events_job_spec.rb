require "rails_helper"

RSpec.describe PurgeDomainEventsJob, type: :job do
  before { Current.city = TEST_CITY_A }

  # Cria um domain_event com occurred_at explícito (default seria Time.current).
  def make_event(occurred_at:, name: "triage.completed")
    ev = DomainEvent.create!(name: name, payload: {}, occurred_at: occurred_at)
    ev.id
  end

  # PurgeDomainEventsJob prepends EachCityJob (roda por cidade ativa via
  # City.where(status: "active")); chamamos o corpo direto, como
  # rebuild_dashboard_metrics_job_spec/reconcile_consents_job_spec (5b item 2)
  # já fazem, para exercitar o purge isoladamente na conexão da cidade que o
  # harness já abriu.
  def call_body(**kwargs)
    described_class.instance_method(:perform).super_method.bind_call(described_class.new, **kwargs)
  end

  it "deletes events older than the 12-month window and keeps recent ones" do
    old_id    = make_event(occurred_at: 13.months.ago)
    recent_id = make_event(occurred_at: 1.month.ago)

    call_body(older_than_months: 12)

    expect(DomainEvent.exists?(old_id)).to be(false)
    expect(DomainEvent.exists?(recent_id)).to be(true)
  end

  it "keeps an event just inside the window (strict < cutoff)" do
    just_inside_id = make_event(occurred_at: 11.months.ago)
    call_body(older_than_months: 12)
    expect(DomainEvent.exists?(just_inside_id)).to be(true)
  end

  it "honors a custom window" do
    two_months_id = make_event(occurred_at: 2.months.ago)
    one_week_id    = make_event(occurred_at: 1.week.ago)
    call_body(older_than_months: 1)
    expect(DomainEvent.exists?(two_months_id)).to be(false)
    expect(DomainEvent.exists?(one_week_id)).to be(true)
  end

  it "roda uma vez por cidade ATIVA (EachCityJob): purga em AMBAS as cidades" do
    city_a = create(:city, database_url: city_database_url("rota_saude_test_city_a"))
    city_b = create(:city, database_url: city_database_url("rota_saude_test_city_b"))

    old_a = CityConnection.with(city_a) { DomainEvent.create!(name: "triage.completed", payload: {}, occurred_at: 13.months.ago).id }
    old_b = CityConnection.with(city_b) { DomainEvent.create!(name: "triage.completed", payload: {}, occurred_at: 13.months.ago).id }

    described_class.new.perform(older_than_months: 12)

    expect(CityConnection.with(city_a) { DomainEvent.exists?(old_a) }).to be(false)
    expect(CityConnection.with(city_b) { DomainEvent.exists?(old_b) }).to be(false)
  end

  it "não visita uma cidade que não está active" do
    suspended = create(:city, database_url: city_database_url("rota_saude_test_city_b"), status: "suspended")
    old_id = CityConnection.with(suspended) { DomainEvent.create!(name: "triage.completed", payload: {}, occurred_at: 13.months.ago).id }

    described_class.new.perform(older_than_months: 12)

    expect(CityConnection.with(suspended) { DomainEvent.exists?(old_id) }).to be(true)
  end
end
