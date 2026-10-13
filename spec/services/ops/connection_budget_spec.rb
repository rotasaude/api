require "rails_helper"

# Rodada especial do 19 (api#74): teto de conexões do Postgres por parte.
RSpec.describe Ops::ConnectionBudget do
  subject(:budget) do
    described_class.new(web_hosts: 2, web_concurrency: 2, web_threads: 5,
                        city_workers: [ 5, 10, 3, 3 ], platform_workers: [ 2 ])
  end

  it "counts the web base and per-city pools at the thread ceiling" do
    expect(budget.web_base).to eq(40)
    expect(budget.web_per_city).to eq(40)
  end

  it "counts each city supervisor on the city database and on the platform" do
    expect(budget.worker_city_db_per_city).to eq(77)
    expect(budget.worker_platform_per_city).to eq(24)
    expect(budget.platform).to eq(12)
  end

  it "sums the role ceiling of one city" do
    expect(budget.role_per_city).to eq(117)
  end

  it "totals for 1, 4 and 10 cities with the reserve" do
    expect(budget.total(1)).to eq(213)
    expect(budget.total(4)).to eq(636)
    expect(budget.total(10)).to eq(1482)
  end

  it "reads the real production files" do
    from_files = described_class.from_files
    expect(from_files.web_hosts).to eq(2)
    expect(from_files.web_threads).to eq(5)
    expect(from_files.city_workers).to eq([ 5, 10, 3, 3 ])
    expect(from_files.platform_workers).to eq([ 2 ])
  end

  it "refuses a non-positive number of cities" do
    expect { budget.total(0) }.to raise_error(ArgumentError, /cidades/)
  end
end
