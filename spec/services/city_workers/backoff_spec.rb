require "rails_helper"

# Spike 2: um filho cujo banco sumiu morre em 0,4 s; sem espera, reiniciaria em
# loop apertado.
RSpec.describe CityWorkers::Backoff do
  subject(:backoff) { described_class.new }

  it "doubles the wait after each consecutive failure, up to the cap" do
    expect((1..10).map { |failures| backoff.delay_for(failures) })
      .to eq([ 1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 64.0, 128.0, 256.0, 300.0 ])
    expect(backoff.delay_for(0)).to eq(0.0)
  end

  it "counts a failure after a short run and starts over after a stable run" do
    expect(backoff.failures_after_exit(3, ran_for: 5.0)).to eq(4)
    expect(backoff.failures_after_exit(3, ran_for: 600.0)).to eq(1)
  end
end
