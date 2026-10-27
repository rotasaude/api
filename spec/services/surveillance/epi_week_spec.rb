require "rails_helper"

# Módulo 25: semana epidemiológica do Sinan (domingo a sábado; a semana 1 é a
# que contém 4 de janeiro; alguns anos têm a semana 53).
RSpec.describe Surveillance::EpiWeek do
  include ActiveSupport::Testing::TimeHelpers

  {
    "2021-01-02" => "2020-53", "2021-01-03" => "2021-01", "2022-01-01" => "2021-52", "2022-01-02" => "2022-01",
    "2025-12-28" => "2025-53", "2026-01-03" => "2025-53", "2026-01-04" => "2026-01", "2026-10-24" => "2026-42",
    "2026-10-25" => "2026-43", "2026-10-27" => "2026-43", "2027-01-02" => "2026-52", "2027-01-03" => "2027-01"
  }.each do |date, week|
    it("#{date} → #{week}") { expect(described_class.for(Date.iso8601(date)).to_s).to eq(week) }
  end

  it "domingo a sábado; parse recusa semana que não existe; between atravessa a virada" do
    w = described_class.parse("2025-53")
    expect([ w.starts_on, w.ends_on ]).to eq([ Date.new(2025, 12, 28), Date.new(2026, 1, 3) ])
    expect(described_class.parse("2026-53")).to be_nil
    expect(described_class.parse("2026-1")).to be_nil
    expect(w.succ.to_s).to eq("2026-01")
    expect(described_class.between(described_class.parse("2025-52"), described_class.parse("2026-02")).map(&:to_s))
      .to eq(%w[2025-52 2025-53 2026-01 2026-02])
  end

  describe ".parse" do
    it "devolve nil para texto malformado, semana zero e valor que não é texto" do
      ["2026-1", "2026-00", "2026-001", "26-01", "2026/01", " 2026-01", "2026-01\n", "abc", "", nil, 202601].each do |bad|
        expect(described_class.parse(bad)).to be_nil, "esperava nil para #{bad.inspect}"
      end
    end

    it "aceita só semanas que existem no ano (53 apenas em anos de 53 semanas)" do
      expect(described_class.parse("2026-52").to_s).to eq("2026-52")
      expect(described_class.parse("2026-53")).to be_nil
      expect(described_class.parse("2020-53").to_s).to eq("2020-53")
      expect(described_class.parse("2021-53")).to be_nil
    end
  end

  describe "navegação" do
    let(:w) { described_class.parse("2026-43") }

    it "range cobre domingo a sábado" do
      expect(w.range).to eq(Date.new(2026, 10, 25)..Date.new(2026, 10, 31))
      expect(w.starts_on).to be_sunday
      expect(w.ends_on).to be_saturday
    end

    it "succ e pred atravessam o fim do ano, inclusive a semana 53" do
      expect(described_class.parse("2026-52").succ.to_s).to eq("2027-01")
      expect(described_class.parse("2027-01").pred.to_s).to eq("2026-52")
      expect(described_class.parse("2026-01").pred.to_s).to eq("2025-53")
      expect(described_class.parse("2025-53").succ.to_s).to eq("2026-01")
    end

    it "#- volta n semanas, atravessando a virada" do
      expect((w - 0).to_s).to eq("2026-43")
      expect((w - 1).to_s).to eq("2026-42")
      expect((w - 42).to_s).to eq("2026-01")
      expect((w - 43).to_s).to eq("2025-53")
      expect((described_class.parse("2026-02") - 3).to_s).to eq("2025-52")
    end

    it "compara por ano e semana" do
      a = described_class.parse("2025-53")
      b = described_class.parse("2026-01")
      expect(a).to be < b
      expect([ b, a ].sort).to eq([ a, b ])
      expect(a).to eq(described_class.parse("2025-53"))
      expect(described_class.parse("2026-01")).to be > described_class.parse("2025-52")
    end
  end

  describe ".between" do
    it "inclui as duas pontas; uma semana só devolve ela mesma" do
      w = described_class.parse("2026-10")
      expect(described_class.between(w, w)).to eq([ w ])
      expect(described_class.between(w, w.succ).map(&:to_s)).to eq(%w[2026-10 2026-11])
    end

    it "devolve lista vazia quando from vem depois de to" do
      expect(described_class.between(described_class.parse("2026-05"), described_class.parse("2026-04"))).to eq([])
    end
  end

  describe ".current" do
    it "usa a data recebida" do
      expect(described_class.current(Date.new(2026, 10, 27)).to_s).to eq("2026-43")
    end

    it "sem argumento, usa Time.zone.today" do
      travel_to Time.zone.local(2026, 10, 27, 12) do
        expect(described_class.current.to_s).to eq("2026-43")
      end
    end
  end
end
