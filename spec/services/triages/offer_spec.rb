# spec/services/triages/offer_spec.rb
require "rails_helper"

# Regra de oferta do ADR 0027 (spec 2026-10-05 §5.1), como função pura: data
# fixa de propósito (on: é argumento, não relógio).
RSpec.describe Triages::Offer, ".evaluate" do
  let(:on) { Date.new(2026, 10, 5) }
  let(:idoso) { { "title" => "Saúde do idoso", "summary" => "Anual.", "eligibility" => { "gte" => ["profile.age", 60] }, "retake_after_days" => 365 } }

  def protocol(name, offer = nil) = { name: name, offer: offer }
  def row(**attrs) = described_class::Row.new(**{ enabled: true, position: 0, restriction: nil, available_from: nil, available_until: nil }.merge(attrs))
  def ctx(age: 62, sex: "female", neighborhood_id: nil)
    Protocols::ConditionContext.build(profile: { age: age, sex: sex }, citizen: { neighborhood_id: neighborhood_id })
  end

  def evaluate(protocols, rows: {}, context: ctx, last_completed: {})
    described_class.evaluate(protocols: protocols, rows: rows, context: context, last_completed: last_completed, on: on)
  end

  def names(...) = evaluate(...).map(&:protocol_name)

  it "sem linha: em oferta só sem elegibilidade (catálogo vazio = hoje)" do
    expect(names([ protocol("respiratoria"), protocol("idoso", idoso) ])).to eq([ "respiratoria" ])
  end

  it "com linha: enabled e dentro do período; pausado some" do
    expect(names([ protocol("idoso", idoso) ], rows: { "idoso" => row })).to eq([ "idoso" ])
    expect(names([ protocol("idoso", idoso) ], rows: { "idoso" => row(enabled: false) })).to eq([])
  end

  it "período: bordas inclusivas" do
    {
      { available_from: on } => [ "x" ], { available_until: on } => [ "x" ],
      { available_from: on + 1 } => [], { available_until: on - 1 } => [],
      { available_from: on - 10, available_until: on + 10 } => [ "x" ]
    }.each do |period, expected|
      expect(names([ protocol("x") ], rows: { "x" => row(**period) })).to eq(expected), period.inspect
    end
  end

  it "idade nas bordas: 59 fora, 60 dentro; sexo pela elegibilidade" do
    rows = { "idoso" => row }
    expect(names([ protocol("idoso", idoso) ], rows: rows, context: ctx(age: 59))).to eq([])
    expect(names([ protocol("idoso", idoso) ], rows: rows, context: ctx(age: 60))).to eq([ "idoso" ])
    mulher = { "eligibility" => { "eq" => ["profile.sex", "female"] } }
    expect(names([ protocol("mulher", mulher) ], rows: { "mulher" => row }, context: ctx(sex: "male"))).to eq([])
  end

  it "restrição soma com E e nunca amplia" do
    centro = "0b6f6c1e-9f1a-4d8b-9a4c-1f2e3d4c5b6a"
    no_centro = row(restriction: { "in" => ["citizen.neighborhood_id", [centro]] })
    expect(names([ protocol("idoso", idoso) ], rows: { "idoso" => no_centro }, context: ctx(neighborhood_id: centro))).to eq([ "idoso" ])
    expect(names([ protocol("idoso", idoso) ], rows: { "idoso" => no_centro }, context: ctx)).to eq([])
    tudo = row(restriction: { "gte" => ["profile.age", 0] })
    expect(names([ protocol("idoso", idoso) ], rows: { "idoso" => tudo }, context: ctx(age: 30))).to eq([])
  end

  it "restrição quebrada (gravada por fora) deixa o protocolo fora, sem levantar" do
    [ "lixo", { "xyz" => 1 }, { "all" => "x" }, { "gte" => ["profile.age"] } ].each do |broken|
      expect(names([ protocol("x") ], rows: { "x" => row(restriction: broken) })).to eq([]), broken.inspect
    end
  end

  it "intervalo: recent com next_available_on; no dia exato volta a available" do
    item = evaluate([ protocol("idoso", idoso) ], rows: { "idoso" => row }, last_completed: { "idoso" => Date.new(2026, 3, 10) }).sole
    expect(item).to have_attributes(state: "recent", last_completed_on: Date.new(2026, 3, 10),
                                    next_available_on: Date.new(2027, 3, 10))
    item = evaluate([ protocol("idoso", idoso) ], rows: { "idoso" => row }, last_completed: { "idoso" => on - 365 }).sole
    expect(item).to have_attributes(state: "available", next_available_on: nil)
    item = evaluate([ protocol("sem-intervalo") ], last_completed: { "sem-intervalo" => on }).sole
    expect(item.state).to eq("available")
  end

  it "perfil ausente: elegibilidade falsa, protocolo sem elegibilidade continua" do
    empty = Protocols::ConditionContext.build
    expect(names([ protocol("idoso", idoso), protocol("x") ], rows: { "idoso" => row }, context: empty)).to eq([ "x" ])
  end

  it "ordem: position do catálogo, depois título; sem linha por último; título cai para o name" do
    items = evaluate([ protocol("c-sem-linha"), protocol("b", { "title" => "Bê" }), protocol("a", { "title" => "Á" }) ],
                     rows: { "a" => row(position: 2), "b" => row(position: 1) })
    expect(items.map(&:protocol_name)).to eq(%w[b a c-sem-linha])
    expect(items.map(&:title)).to eq([ "Bê", "Á", "c-sem-linha" ])
    expect(items.last.summary).to be_nil
  end

  it "offer malformado no banco é tratado como ausente" do
    expect(names([ protocol("x", "lixo") ])).to eq([ "x" ])
  end
end
