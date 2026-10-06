require "rails_helper"

# Review Focus 5: espera crescente, teto de 2 h, desistência 24 h depois da
# PRIMEIRA tentativa.
RSpec.describe Ledi::Backoff do
  it "dobra a partir de 1 minuto até o teto de 2 horas" do
    expect((1..9).map { |n| described_class.wait(n).to_i / 60 }).to eq([ 1, 2, 4, 8, 16, 32, 64, 120, 120 ])
  end

  it "desiste 24 h depois da primeira tentativa" do
    expect(described_class::GIVE_UP_AFTER).to eq(24.hours)
  end
end
