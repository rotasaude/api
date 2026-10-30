require "rails_helper"

# Módulo 27a, Task 9 (ADR 0045, Desvio 8; contrato H3; Review Focus 1): a
# validade da receita POR ITEM, em dia inclusivo no fuso da cidade, com os
# prazos lidos dos parâmetros da cidade na hora.
RSpec.describe Pharmacy::Validity do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { pharmacy_city! }
  def settings = Pharmacy::Settings.current # sem memoizar: a cidade é lida na hora
  let(:day) { Date.new(2026, 10, 1) }

  def item_until(issued_on: day, explicit: nil, continuous: false, controlled: false, external: false)
    described_class.item_until(issued_on: issued_on, explicit: explicit, continuous: continuous, controlled: controlled, external: external,
                               settings: settings)
  end

  it "comum sem prazo: a emissão + 30 dias; contínua: + 180" do
    expect(item_until).to eq(day + 30)
    expect(item_until(continuous: true)).to eq(day + 180)
  end

  it "com valid_until explícito (a data do conteúdo do 19c) vale ele, mesmo contínuo" do
    expect(item_until(explicit: day + 7)).to eq(day + 7)
    expect(item_until(explicit: day + 7, continuous: true)).to eq(day + 7)
  end

  it "externa controlada: 30 dias fixos, mesmo contínua; a controlada do 19c segue o prazo gravado" do
    expect(item_until(external: true, controlled: true, continuous: true)).to eq(day + 30)
    expect(item_until(external: true, controlled: false, continuous: true)).to eq(day + 180)
    expect(item_until(external: false, controlled: true, explicit: day + 30)).to eq(day + 30)
  end

  it "o prazo da cidade é lido na hora: mudar common_validity_days para 60 muda a conta" do
    expect(item_until).to eq(day + 30)
    PharmacySetting.find(1).update!(common_validity_days: 60)
    expect(item_until).to eq(day + 60)
    PharmacySetting.find(1).update!(continuous_validity_days: 90)
    expect(item_until(continuous: true)).to eq(day + 90)
  end

  describe "fuso da cidade (Review Focus 1)" do
    around { |example| Time.use_zone("America/Sao_Paulo") { example.run } }

    it "emitida em 30/09 às 23:30 (já 01/10 em UTC) vale até 30/10 inclusive; vence só no dia seguinte" do
      issued_at = Time.zone.parse("2026-09-30 23:30:00 -03:00")
      expect(issued_at.utc.to_date).to eq(Date.new(2026, 10, 1))
      valid_until = item_until(issued_on: issued_at.in_time_zone.to_date)
      expect(valid_until).to eq(Date.new(2026, 10, 30))

      travel_to(Time.zone.parse("2026-10-30 23:50:00 -03:00")) { expect(described_class.expired?(valid_until)).to be(false) }
      travel_to(Time.zone.parse("2026-10-31 00:10:00 -03:00")) { expect(described_class.expired?(valid_until)).to be(true) }
    end

    it "o dia da validade ainda vale; o seguinte não (today > until)" do
      expect(described_class.expired?(Date.new(2026, 10, 30), today: Date.new(2026, 10, 30))).to be(false)
      expect(described_class.expired?(Date.new(2026, 10, 30), today: Date.new(2026, 10, 31))).to be(true)
    end
  end
end
