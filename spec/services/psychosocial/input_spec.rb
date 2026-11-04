require "rails_helper"

# Módulo 31 (fix round 1 da Task 4): data/hora sem offset é lida no fuso da
# cidade, não em UTC (o mês de uma ação ou de um acolhimento é o local).
RSpec.describe Psychosocial::Input do
  around { |example| Time.use_zone("America/Sao_Paulo") { example.run } }

  describe ".time" do
    it "sem offset: hora local da cidade (23:30 de 30/11 é novembro)" do
      time = described_class.time("2026-11-30T23:30")
      expect(time.month).to eq(11)
      expect(time.utc).to eq(Time.utc(2026, 12, 1, 2, 30))
    end

    it "com offset ou Z: o instante informado, no fuso da cidade" do
      expect(described_class.time("2026-12-01T02:30:00Z")).to eq(Time.utc(2026, 12, 1, 2, 30))
      expect(described_class.time("2026-11-30T23:30:00-03:00").utc).to eq(Time.utc(2026, 12, 1, 2, 30))
      expect(described_class.time("2026-12-01T02:30:00Z").time_zone.name).to eq("America/Sao_Paulo")
    end

    it "só a data, texto inválido ou não string → nil" do
      expect(described_class.time("2026-11-30")).to be_nil
      expect(described_class.time("2026-13-40T25:99")).to be_nil
      expect(described_class.time(nil)).to be_nil
      expect(described_class.time(1)).to be_nil
    end
  end

  describe ".date" do
    it "ISO estrito" do
      expect(described_class.date("2026-11-30")).to eq(Date.new(2026, 11, 30))
      expect(described_class.date("2026-02-30")).to be_nil
      expect(described_class.date("30/11/2026")).to be_nil
    end
  end
end
