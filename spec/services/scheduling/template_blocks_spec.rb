require "rails_helper"

# Contratos §3, §9: cada recusa com o seu detail.
RSpec.describe Scheduling::TemplateBlocks do
  before { Current.city = TEST_CITY_A; ensure_appointment_types!; type_row!("acupuntura", active: false) }
  after { Current.reset }

  let(:catalog) { Scheduling::AppointmentTypes.catalog }
  def b(starts, ends, kind = "bookable", key = "consulta_medica", slot = nil)
    { "starts" => starts, "ends" => ends, "kind" => kind, "appointment_type_key" => key, "slot_minutes" => slot }.compact
  end

  it "aceita as três faixas sem sobreposição (encostadas valem)" do
    blocks = [ b("07:00", "09:00", "walk_in", nil), b("09:00", "11:00"), b("11:00", "12:00", "blocked", nil) ]
    expect(described_class.detail(blocks, catalog)).to be_nil
  end

  {
    "lista vazia" => [ [], :empty ],
    "não é lista" => [ "x", :bad_block ],
    "faixa que não é objeto" => [ [ "x" ], :bad_block ],
    "chave desconhecida" => [ [ { "starts" => "09:00", "ends" => "10:00", "kind" => "blocked", "cor" => "azul" } ], :bad_block ],
    "kind desconhecido" => [ [ { "starts" => "09:00", "ends" => "10:00", "kind" => "folga" } ], :bad_block ],
    "tipo em faixa que não é bookable" => [ [ { "starts" => "09:00", "ends" => "10:00", "kind" => "walk_in", "appointment_type_key" => "retorno" } ], :bad_block ],
    "hora malformada" => [ [ { "starts" => "9:00", "ends" => "10:00", "kind" => "blocked" } ], :bad_time ],
    "minuto inválido" => [ [ { "starts" => "09:60", "ends" => "10:00", "kind" => "blocked" } ], :bad_time ],
    "fim antes do início" => [ [ { "starts" => "10:00", "ends" => "09:00", "kind" => "blocked" } ], :crosses_midnight ],
    "fim 24:00" => [ [ { "starts" => "22:00", "ends" => "24:00", "kind" => "blocked" } ], :crosses_midnight ],
    "bookable sem tipo" => [ [ { "starts" => "09:00", "ends" => "10:00", "kind" => "bookable" } ], :missing_type ],
    "tipo inexistente" => [ [ { "starts" => "09:00", "ends" => "10:00", "kind" => "bookable", "appointment_type_key" => "fantasma" } ], :unknown_type ],
    "tipo desativado" => [ [ { "starts" => "09:00", "ends" => "10:00", "kind" => "bookable", "appointment_type_key" => "acupuntura" } ], :inactive_type ],
    "slot_minutes fora de 5–240" => [ [ { "starts" => "09:00", "ends" => "10:00", "kind" => "bookable", "appointment_type_key" => "retorno", "slot_minutes" => 4 } ], :bad_slot_minutes ],
    "slot_minutes texto" => [ [ { "starts" => "09:00", "ends" => "10:00", "kind" => "bookable", "appointment_type_key" => "retorno", "slot_minutes" => "15" } ], :bad_slot_minutes ],
    "sobreposição" => [ [ { "starts" => "09:00", "ends" => "10:00", "kind" => "blocked" }, { "starts" => "09:30", "ends" => "11:00", "kind" => "walk_in" } ], :overlap ]
  }.each do |name, (blocks, detail)|
    it("#{name} → #{detail}") { expect(described_class.detail(blocks, catalog)).to eq(detail) }
  end

  it "até 24 faixas vale; a 25ª → bad_block" do
    hhmm = ->(m) { format("%02d:%02d", m / 60, m % 60) }
    blocks = (0..24).map { |i| { "starts" => hhmm.(i * 40), "ends" => hhmm.(i * 40 + 30), "kind" => "blocked" } }
    expect(described_class.detail(blocks.first(24), catalog)).to be_nil
    expect(described_class.detail(blocks, catalog)).to eq(:bad_block)
  end

  it "slot_minutes em faixa que não é bookable → bad_block" do
    expect(described_class.detail([ { "starts" => "09:00", "ends" => "10:00", "kind" => "walk_in", "slot_minutes" => 15 } ], catalog))
      .to eq(:bad_block)
  end

  it "slot_minutes nos limites 5 e 240 vale" do
    expect(described_class.detail([ b("08:00", "09:00", "bookable", "retorno", 5), b("09:00", "13:00", "bookable", "retorno", 240) ], catalog))
      .to be_nil
    expect(described_class.detail([ b("09:00", "14:00", "bookable", "retorno", 241) ], catalog)).to eq(:bad_slot_minutes)
  end

  it "aceita faixas com chaves em símbolo (lê as horas, não 00:00)" do
    expect(described_class.detail([ { starts: "09:00", ends: "10:00", kind: "blocked" }, { starts: "09:30", ends: "11:00", kind: "walk_in" } ], catalog))
      .to eq(:overlap)
    expect(described_class.normalize([ { starts: "09:00", ends: "10:00", kind: "blocked" } ]))
      .to eq([ { "starts" => "09:00", "ends" => "10:00", "kind" => "blocked" } ])
  end

  it "normalize guarda só as chaves do contrato, em texto" do
    expect(described_class.normalize([ ActiveSupport::HashWithIndifferentAccess.new(b("09:00", "10:00", "bookable", "retorno", 15)) ]))
      .to eq([ { "starts" => "09:00", "ends" => "10:00", "kind" => "bookable", "appointment_type_key" => "retorno", "slot_minutes" => 15 } ])
  end
end
