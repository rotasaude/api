require "rails_helper"

# F-23.8 (ADR 0040; ADR 0027): oferta com intervalo de repetição passado.
RSpec.describe Triages::Offer, "triagem periódica vencida" do
  let(:on) { Date.new(2026, 10, 22) }
  let(:protocols) do
    [ { name: "saude-idoso", offer: { "title" => "Saúde do idoso", "retake_after_days" => 180 } },
      { name: "rastreio-sem-intervalo", offer: { "title" => "Rastreio" } } ]
  end

  def evaluate(last_completed)
    described_class.evaluate(protocols: protocols, rows: {}, context: {}, last_completed: last_completed, on: on).index_by(&:protocol_name)
  end

  it "vencida: feita há mais que o intervalo; recente: não; nunca feita: não vencida; sem intervalo: sem campo" do
    overdue = evaluate("saude-idoso" => on - 200, "rastreio-sem-intervalo" => on - 400)
    expect(overdue["saude-idoso"]).to have_attributes(state: "available", retake_after_days: 180)
    expect(overdue["saude-idoso"].overdue?).to be(true)
    expect(Triages::Catalog.item_json(overdue["saude-idoso"])).to include(overdue: true, last_done_at: (on - 200).iso8601)
    expect(Triages::Catalog.item_json(overdue["rastreio-sem-intervalo"])).not_to have_key(:overdue)
    expect(overdue["rastreio-sem-intervalo"].overdue?).to be(false)
    expect(evaluate("saude-idoso" => on - 100)["saude-idoso"].overdue?).to be(false)
    never = evaluate({})["saude-idoso"]
    expect(never.overdue?).to be(false)
    expect(Triages::Catalog.item_json(never)).to include(overdue: false, last_done_at: nil)
  end
end
