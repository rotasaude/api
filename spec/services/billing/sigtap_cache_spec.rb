require "rails_helper"

# Revisão final, I2: fechamento, pendências e resumo leem a SIGTAP uma vez
# por release e código dentro da chamada (Billing::SigtapCache, por chamada,
# sem estado global) — o número de consultas não cresce com N procedimentos.
RSpec.describe Billing::SigtapCache do
  before do
    billing_city!
    billing_settings!
  end

  let(:clerk) { billing_clerk! }
  let(:patient) { billing_patient! }

  def sigtap_queries
    count = 0
    callback = lambda do |*, payload|
      count += 1 if payload[:sql].match?(/sigtap_procedure|terminology_releases/) && payload[:name] != "SCHEMA"
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    count
  end

  def period_with(count)
    unit = upa!
    doctor = doctor!(unit)
    procedures = Array.new(count) { recorded_procedure!(unit: unit, professional: doctor, patient: patient) }
    procedures.first.billing_period
  end

  it "pendências, resumo e fechamento: consultas SIGTAP não crescem com o número de procedimentos" do
    small = period_with(2)
    large = period_with(6)
    expect(sigtap_queries { Billing::Pending.call(large) }).to eq(sigtap_queries { Billing::Pending.call(small) })
    expect(sigtap_queries { Billing::Summary.call(large) }).to eq(sigtap_queries { Billing::Summary.call(small) })
    expect(sigtap_queries { Billing::Close.call(period: large, by: clerk) }).to eq(sigtap_queries { Billing::Close.call(period: small, by: clerk) })
    expect(large.reload).to be_closed
  end

  it "memoriza por chamada: a mesma release e o mesmo código não voltam ao banco" do
    period_with(1)
    cache = described_class.new
    competence = Time.zone.today.strftime("%Y%m")
    first = sigtap_queries do
      release = cache.release(competence)
      cache.procedure(release, "0301060029")
      cache.instruments(release, "0301060029")
      cache.cbos(release, "0301060029")
      cache.cids(release, "0301060029")
    end
    again = sigtap_queries do
      release = cache.release(competence)
      cache.procedure(release, "0301060029")
      cache.instruments(release, "0301060029")
      cache.cbos(release, "0301060029")
      cache.cids(release, "0301060029")
    end
    expect(first).to be_positive
    expect(again).to eq(0)
    expect(described_class.new.release(competence)).to eq(cache.release(competence))
  end
end
