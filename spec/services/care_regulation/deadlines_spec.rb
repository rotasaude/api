require "rails_helper"

# Módulo 26a (ADR 0044; contrato §6, G5, ruling da Task 2): prazos por cor.
RSpec.describe CareRegulation::Deadlines do
  let(:admin) { regulation_admin! }

  # O banco de cidade carregado do dump nasce sem linhas (a migração insere os
  # padrões): `rows!` as cria, como o regulation_city!.
  def rows! = RegulationRiskDeadline.ensure_defaults!

  def save(attrs) = CareRegulation::SaveDeadlines.call(attrs: attrs, by: admin)

  it "cidade sem linhas: os padrões 7/30/90/180, nunca erro" do
    expect(RegulationRiskDeadline.count).to eq(0)
    expect(described_class.all).to eq("red" => 7, "yellow" => 30, "green" => 90, "blue" => 180)
    expect(described_class.days("blue")).to eq(180)
    expect(described_class.due_on(requested_at: Time.zone.parse("2026-10-10 10:00"), color: "yellow")).to eq(Date.new(2026, 11, 9))
  end

  it "due_on conta da data do pedido no fuso da cidade (America/Sao_Paulo)" do
    Time.use_zone("America/Sao_Paulo") do
      requested = Time.zone.parse("2026-10-31 23:30")
      expect(described_class.due_on(requested_at: requested, color: "red")).to eq(Date.new(2026, 11, 7))
      # o mesmo instante em UTC já é 1º de novembro, mas a data do pedido é a da cidade
      expect(described_class.due_on(requested_at: requested.utc, color: "red")).to eq(Date.new(2026, 11, 7))
    end
  end

  it "cor desconhecida levanta KeyError" do
    expect { described_class.days("purple") }.to raise_error(KeyError)
  end

  it "SaveDeadlines grava as quatro cores (upsert) e days passa a devolvê-las" do
    rows!
    result = save("red" => 3, "yellow" => 20, "green" => 60, "blue" => 120)
    expect(result).to be_ok
    expect(result.payload.fetch(:deadlines)).to eq("red" => 3, "yellow" => 20, "green" => 60, "blue" => 120)
    expect(described_class.days("red")).to eq(3)
    expect(RegulationRiskDeadline.count).to eq(4)
    expect(RegulationRiskDeadline.find("red").updated_by_user).to eq(admin)
  end

  it "SaveDeadlines faz upsert mesmo sem linhas (banco do dump)" do
    expect(RegulationRiskDeadline.count).to eq(0)
    expect(save("red" => 1, "yellow" => 2, "green" => 3, "blue" => 4)).to be_ok
    expect(RegulationRiskDeadline.pluck(:color, :days).to_h).to eq("red" => 1, "yellow" => 2, "green" => 3, "blue" => 4)
  end

  it "os quatro são obrigatórios, inteiros de 1 a 365" do
    rows!
    base = { "red" => 7, "yellow" => 30, "green" => 90, "blue" => 180 }
    [ [ "blue", 0 ], [ "red", 366 ], [ "green", "90" ], [ "yellow", 30.5 ], [ "red", nil ], [ "blue", true ], [ "yellow", -1 ] ].each do |color, value|
      result = save(base.merge(color => value))
      expect([ result.reason, result.details ]).to eq([ :invalid_request, { path: color } ])
    end
    expect(save(base.except("green")).details).to eq(path: "green")
    expect(save(base.merge("red" => 1, "blue" => 365))).to be_ok
    expect(described_class.all).to eq("red" => 1, "yellow" => 30, "green" => 90, "blue" => 365)
  end

  it "G5: cor menos grave com prazo menor que a mais grave → invalid_deadlines na cor menos grave; a tabela não muda" do
    rows!
    result = save("red" => 7, "yellow" => 5, "green" => 90, "blue" => 180)
    expect([ result.reason, result.details ]).to eq([ :invalid_deadlines, { path: "yellow" } ])
    expect(save("red" => 7, "yellow" => 30, "green" => 20, "blue" => 180).details).to eq(path: "green")
    expect(save("red" => 7, "yellow" => 30, "green" => 90, "blue" => 80).details).to eq(path: "blue")
    expect(described_class.all).to eq("red" => 7, "yellow" => 30, "green" => 90, "blue" => 180)
    expect(save("red" => 7, "yellow" => 7, "green" => 7, "blue" => 7)).to be_ok
  end

  it "o formato vem antes da ordem" do
    expect(save("red" => 7, "yellow" => 5, "green" => 90, "blue" => 0).details).to eq(path: "blue")
  end

  it "publica care_regulation.settings_changed só com user_id, e só quando algo muda" do
    rows!
    save("red" => 3, "yellow" => 20, "green" => 60, "blue" => 120)
    save("red" => 3, "yellow" => 20, "green" => 60, "blue" => 120)
    events = DomainEvent.where(name: "care_regulation.settings_changed")
    expect(events.map(&:payload)).to eq([ { "user_id" => admin.id } ])
  end

  it "due_on lê a tabela na hora da conta (o que já foi calculado não muda)" do
    rows!
    before = described_class.due_on(requested_at: Time.zone.parse("2026-10-10 10:00"), color: "red")
    save("red" => 3, "yellow" => 20, "green" => 60, "blue" => 120)
    expect(described_class.due_on(requested_at: Time.zone.parse("2026-10-10 10:00"), color: "red")).to eq(before - 4)
  end
end
