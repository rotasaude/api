require "rails_helper"

# Contratos §1 (parâmetros) e desvio 5 do plano.
RSpec.describe Analytics::Params do
  let(:today) { Time.zone.today }
  let(:yesterday) { today - 1 }
  let(:base) { { from: (today - 20).iso8601, to: yesterday.iso8601 } }
  let(:centro) { Neighborhood.create!(name: "Centro", source: "manual", active: false) }
  let(:unit) { create_unit("UBS Centro") }
  let!(:protocol) { create_default_protocol! }

  def parse(front = "demand", **raw) = described_class.new(front, ActionController::Parameters.new(raw), today: today)

  def code(front = "demand", **raw)
    parse(front, **raw)
    nil
  rescue described_class::Invalid => e
    e.code
  end

  it "datas obrigatórias em AAAA-MM-DD, válidas e em ordem; to depois de ontem vira ontem" do
    expect(code(to: yesterday.iso8601)).to eq("invalid_range")
    expect(code(from: "2026-02-30", to: yesterday.iso8601)).to eq("invalid_range")
    expect(code(from: (today - 3).strftime("%d/%m/%Y"), to: yesterday.iso8601)).to eq("invalid_range")
    expect(code(from: (today - 3).iso8601, to: (today - 5).iso8601)).to eq("invalid_range")
    expect(code(from: today.iso8601, to: (today + 5).iso8601)).to eq("invalid_range")
    expect(parse(from: (today - 10).iso8601, to: (today + 5).iso8601).to).to eq(yesterday)
  end

  it "granularidade: week por padrão, month, nada mais; teto de 104 semanas e de 60 meses" do
    expect(parse(**base).granularity).to eq("week")
    expect(code(**base, granularity: "day")).to eq("invalid_range")

    first_week = yesterday.beginning_of_week - (103 * 7)
    expect(code(from: first_week.iso8601, to: yesterday.iso8601)).to be_nil
    expect(code(from: (first_week - 7).iso8601, to: yesterday.iso8601)).to eq("invalid_range")

    first_month = yesterday.beginning_of_month << 59
    expect(code(from: first_month.iso8601, to: yesterday.iso8601, granularity: "month")).to be_nil
    expect(code(from: (first_month << 1).iso8601, to: yesterday.iso8601, granularity: "month")).to eq("invalid_range")
  end

  it "períodos: segunda-feira (week) ou dia 1 (month), do período do from ao do to" do
    week = parse(**base)
    expect(week.periods).to eq(((today - 20).beginning_of_week..yesterday.beginning_of_week).step(7).to_a)
    expect(week.period_sql).to eq("date_trunc('week', day)::date")

    month = parse(from: (yesterday << 2).iso8601, to: yesterday.iso8601, granularity: "month")
    expect(month.periods).to eq([ (yesterday << 2).beginning_of_month, (yesterday << 1).beginning_of_month,
                                  yesterday.beginning_of_month ])
  end

  it "recortes válidos: bairro (inclusive inativo) ou none, unidade, protocolo e versão" do
    expect(parse(**base, neighborhood_id: centro.id)).to have_attributes(neighborhood?: true, neighborhood_value: centro.id)
    expect(parse(**base, neighborhood_id: "none")).to have_attributes(neighborhood?: true, neighborhood_value: nil)
    expect(parse(**base)).to have_attributes(neighborhood?: false)
    expect(parse(**base, health_unit_id: unit.id).health_unit_id).to eq(unit.id)
    calibration = parse("calibration", **base, protocol_name: protocol.name, protocol_version: "1")
    expect(calibration.filter).to eq(neighborhood_id: nil, health_unit_id: nil, protocol_name: protocol.name,
                                     protocol_version: 1)
  end

  it "recortes inválidos devolvem o código do contrato" do
    expect(code(**base, neighborhood_id: SecureRandom.uuid)).to eq("invalid_neighborhood")
    expect(code(**base, neighborhood_id: "centro")).to eq("invalid_neighborhood")
    expect(code(**base, health_unit_id: SecureRandom.uuid)).to eq("invalid_unit")
    expect(code(**base, protocol_name: "nao-existe")).to eq("invalid_protocol")
    expect(code("calibration", **base, protocol_version: "1")).to eq("invalid_protocol")
    expect(code("calibration", **base, protocol_name: protocol.name, protocol_version: "9")).to eq("invalid_protocol")
    expect(code("calibration", **base, protocol_name: protocol.name, protocol_version: "1x")).to eq("invalid_protocol")
  end

  it "recorte que não vale para a frente é ignorado e volta nulo" do
    quality = parse("quality", **base, neighborhood_id: "lixo", protocol_name: "lixo", health_unit_id: unit.id)
    expect(quality.filter).to eq(neighborhood_id: nil, health_unit_id: unit.id, protocol_name: nil, protocol_version: nil)
  end

  it "calibração: sem granularidade nem períodos, intervalo de até 60 meses" do
    calibration = parse("calibration", **base, granularity: "lixo")
    expect(calibration).to have_attributes(granularity: nil, periods: [])
    first_month = yesterday.beginning_of_month << 60
    expect(code("calibration", from: first_month.iso8601, to: yesterday.iso8601)).to eq("invalid_range")
  end
end
