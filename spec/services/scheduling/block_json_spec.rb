require "rails_helper"

# Contratos §2, §9, §10: faixas efetivas em HH:MM locais, uma entrada por dia
# local; o recorte que chega à meia-noite sai como "24:00"; bookable com nome.
RSpec.describe Scheduling::BlockJson do
  before { Current.city = TEST_CITY_A; ensure_appointment_types! }
  after { Current.reset }

  let(:zone) { Time.zone }
  let(:catalog) { Scheduling::AppointmentTypes.catalog }
  let(:day) { Date.new(2026, 11, 10) }
  def at(date, hour, min = 0) = zone.local(date.year, date.month, date.day, hour, min)
  def block(starts, ends, kind = "bookable", key = "retorno", slot = nil)
    Scheduling::Availability::Block.new(starts_at: starts, ends_at: ends, kind: kind, appointment_type_key: key, slot_minutes: slot)
  end

  it "parte a faixa que cruza a meia-noite em dois dias, com 24:00 no fim do primeiro" do
    out = described_class.list([ block(at(day, 22), at(day + 1, 2), "bookable", "retorno", 15) ], zone: zone, catalog: catalog)
    expect(out).to eq([
      { starts: "22:00", ends: "24:00", kind: "bookable", appointment_type_key: "retorno", appointment_type_name: "Retorno", slot_minutes: 15 },
      { starts: "00:00", ends: "02:00", kind: "bookable", appointment_type_key: "retorno", appointment_type_name: "Retorno", slot_minutes: 15 }
    ])
  end

  it "faixa que termina exatamente à meia-noite sai inteira no dia, terminando em 24:00" do
    out = described_class.list([ block(at(day, 20), at(day + 1, 0), "blocked", nil) ], zone: zone, catalog: catalog)
    expect(out).to eq([ { starts: "20:00", ends: "24:00", kind: "blocked" } ])
  end

  it "tipo que sumiu do catálogo mostra a própria chave como nome" do
    out = described_class.list([ block(at(day, 9), at(day, 10), "bookable", "fantasma") ], zone: zone, catalog: catalog)
    expect(out.first).to include(appointment_type_key: "fantasma", appointment_type_name: "fantasma")
  end
end
