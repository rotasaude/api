require "rails_helper"

# ADR 0029 §4.1 / spec §9: tabela de casos do cálculo de vagas, puro.
RSpec.describe Scheduling::Availability, ".compute" do
  let(:sp) { ActiveSupport::TimeZone["America/Sao_Paulo"] }
  let(:manaus) { ActiveSupport::TimeZone["America/Manaus"] }
  let(:day) { Date.new(2026, 10, 6) }

  def at(hour, min = 0, d: day, z: sp) = z.local(d.year, d.month, d.day, hour, min)
  def type(key, minutes, prefixes) = described_class::Type.new(key: key, duration_minutes: minutes, cbo_prefixes: prefixes)

  let(:medica) { type("consulta_medica", 20, %w[2251 2252 2253]) }
  let(:enfermagem) { type("consulta_enfermagem", 15, %w[2235]) }
  let(:retorno) { type("retorno", 15, %w[2251 2252 2253 2235 2232]) }
  let(:types) { [ medica, enfermagem, retorno ].index_by(&:key) }
  let(:fallback) { [ medica, enfermagem, retorno ] }

  def shift(starts:, ends:, cbo: "225125", default: nil, blocks: nil, cancelled: false, pro: "p1")
    described_class::Shift.new(id: "s-#{pro}", professional_id: pro, starts_at: starts, ends_at: ends, cbo_code: cbo,
                               default_type_key: default, blocks: blocks, cancelled: cancelled)
  end

  def block(starts, ends, kind, key = nil, slot = nil)
    { "starts" => starts, "ends" => ends, "kind" => kind, "appointment_type_key" => key, "slot_minutes" => slot }.compact
  end

  def hours(shifts, wanted, busy: [], now: at(12, d: day - 1), zone: sp, window: nil)
    described_class.compute(shifts: Array(shifts), type: wanted, types: types, fallback: fallback, busy: busy,
                            now: now, zone: zone, window: window)
                   .map { |s| s.starts_at.in_time_zone(zone).strftime("%d %H:%M") }
  end

  let(:morning) { shift(starts: at(8), ends: at(12)) }
  let(:three_blocks) do
    [ block("07:00", "09:00", "walk_in"), block("09:00", "11:00", "bookable", "consulta_medica"),
      block("11:00", "12:00", "blocked") ]
  end

  it "sem modelo, com tipo padrão do vínculo: o turno inteiro em vagas desse tipo" do
    expect(hours(shift(starts: at(8), ends: at(9), default: "retorno"), retorno))
      .to eq([ "06 08:00", "06 08:15", "06 08:30", "06 08:45" ])
  end

  it "sem modelo e sem padrão: o tipo da base pelo CBO; outro tipo não tem vaga" do
    expect(hours(shift(starts: at(8), ends: at(9)), medica)).to eq([ "06 08:00", "06 08:20", "06 08:40" ])
    expect(hours(shift(starts: at(8), ends: at(9)), retorno)).to eq([])
  end

  it "sem modelo e sem correspondência de CBO: nenhuma vaga (só encaixe)" do
    psicologo = shift(starts: at(8), ends: at(9), cbo: "251510")
    expect(described_class.blocks_for(psicologo, types: types, fallback: fallback, zone: sp)).to eq([])
    expect(hours(psicologo, retorno)).to eq([])
  end

  it "tipo padrão desativado (fora de types) cai para a base" do
    expect(hours(shift(starts: at(8), ends: at(9), default: "acupuntura"), medica)).to eq([ "06 08:00", "06 08:20", "06 08:40" ])
  end

  it "modelo com três faixas: só a agendável do tipo vira vaga" do
    expect(hours(shift(starts: at(7), ends: at(13), blocks: three_blocks), medica))
      .to eq([ "06 09:00", "06 09:20", "06 09:40", "06 10:00", "06 10:20", "06 10:40" ])
    expect(hours(shift(starts: at(7), ends: at(13), blocks: three_blocks), retorno)).to eq([])
  end

  it "faixa fora do turno é recortada pelo turno" do
    expect(hours(shift(starts: at(7), ends: at(13), blocks: [ block("06:00", "08:00", "bookable", "consulta_medica") ]), medica))
      .to eq([ "06 07:00", "06 07:20", "06 07:40" ])
  end

  it "sobra no fim da faixa é descartada; slot_minutes do modelo vale sobre a duração" do
    expect(hours(shift(starts: at(7), ends: at(13), blocks: [ block("09:00", "10:10", "bookable", "consulta_medica") ]), medica))
      .to eq([ "06 09:00", "06 09:20", "06 09:40" ])
    expect(hours(shift(starts: at(7), ends: at(13), blocks: [ block("09:00", "10:00", "bookable", "consulta_medica", 30) ]), medica))
      .to eq([ "06 09:00", "06 09:30" ])
  end

  it "CBO não servido pelo tipo: nenhuma vaga" do
    expect(hours(morning, enfermagem)).to eq([])
  end

  it "vaga cujo início já passou some" do
    expect(hours(shift(starts: at(7), ends: at(13), blocks: three_blocks), medica, now: at(9, 30)))
      .to eq([ "06 09:40", "06 10:00", "06 10:20", "06 10:40" ])
  end

  it "horário ativo do profissional (de qualquer modo) tira as vagas que cruza; o de outro profissional não" do
    busy = [ described_class::Busy.new(professional_id: "p1", starts_at: at(9, 10), ends_at: at(9, 30)),
             described_class::Busy.new(professional_id: "p2", starts_at: at(10), ends_at: at(11)) ]
    expect(hours(shift(starts: at(7), ends: at(13), blocks: three_blocks), medica, busy: busy))
      .to eq([ "06 09:40", "06 10:00", "06 10:20", "06 10:40" ])
  end

  it "turno cancelado: nenhuma vaga" do
    expect(hours(shift(starts: at(8), ends: at(9), cancelled: true), medica)).to eq([])
  end

  it "virada de dia: o modelo vale em cada dia local que o turno cobre" do
    night = shift(starts: at(22), ends: at(2, d: day + 1),
                  blocks: [ block("22:00", "23:00", "bookable", "retorno"), block("00:00", "01:00", "bookable", "retorno") ])
    expect(hours(night, retorno)).to eq([ "06 22:00", "06 22:15", "06 22:30", "06 22:45",
                                          "07 00:00", "07 00:15", "07 00:30", "07 00:45" ])
  end

  it "fuso: as horas do modelo são do fuso da cidade (Manaus, UTC−4)" do
    am = shift(starts: at(8, z: manaus), ends: at(12, z: manaus), blocks: [ block("09:00", "10:00", "bookable", "consulta_medica") ])
    slots = described_class.compute(shifts: [ am ], type: medica, types: types, fallback: fallback, busy: [],
                                    now: at(12, d: day - 1), zone: manaus)
    expect(slots.first.starts_at.utc.strftime("%H:%M")).to eq("13:00")
    expect(slots.size).to eq(3)
  end

  it "janela: só vagas que começam dentro dela; ordem por início e profissional" do
    a = shift(starts: at(8), ends: at(9), pro: "b")
    b = shift(starts: at(8), ends: at(9), pro: "a")
    slots = described_class.compute(shifts: [ a, b ], type: medica, types: types, fallback: fallback, busy: [],
                                    now: at(12, d: day - 1), zone: sp, window: at(8)..at(8, 20))
    expect(slots.map { |s| [ s.professional_id, s.starts_at.in_time_zone(sp).strftime("%H:%M") ] })
      .to eq([ [ "a", "08:00" ], [ "b", "08:00" ], [ "a", "08:20" ], [ "b", "08:20" ] ])
  end

  it "fuso: instantes vindos do banco em UTC usam o fuso da cidade, não o do instante" do
    am = shift(starts: at(8, z: manaus).utc, ends: at(12, z: manaus).utc,
               blocks: [ block("09:00", "10:00", "bookable", "consulta_medica") ])
    expect(hours(am, medica, zone: manaus)).to eq([ "06 09:00", "06 09:20", "06 09:40" ])
  end

  it "virada de dia em Manaus: o dia local é o da cidade (o turno inteiro cai num só dia em UTC)" do
    night = shift(starts: at(20, z: manaus).utc, ends: at(2, d: day + 1, z: manaus).utc,
                  blocks: [ block("21:00", "22:00", "bookable", "retorno"), block("00:00", "01:00", "bookable", "retorno") ])
    expect(night.starts_at.to_date).to eq(night.ends_at.to_date) # em UTC, 07 00:00..07 06:00
    expect(hours(night, retorno, zone: manaus)).to eq([ "06 21:00", "06 21:15", "06 21:30", "06 21:45",
                                                        "07 00:00", "07 00:15", "07 00:30", "07 00:45" ])
  end

  it "virada de dia: faixa do modelo que cai fora do turno em cada dia é descartada" do
    night = shift(starts: at(22), ends: at(2, d: day + 1), blocks: [ block("08:00", "09:00", "bookable", "retorno") ])
    expect(hours(night, retorno)).to eq([])
  end

  it "slice descarta a sobra e devolve pares [início, fim]" do
    b = described_class::Block.new(starts_at: at(9), ends_at: at(9, 50), kind: "bookable",
                                   appointment_type_key: "retorno", slot_minutes: nil)
    expect(described_class.slice(b, 20)).to eq([ [ at(9), at(9, 20) ], [ at(9, 20), at(9, 40) ] ])
  end
end
