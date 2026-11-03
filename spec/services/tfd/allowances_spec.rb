require "rails_helper"

# Módulo 30, Task 11 (ADR 0048; plano, Desvios 13–14; §14 T10, T11; Review
# Focus 3): trechos do TFD e ajuda de custo pela regra federal — deslocamento
# por pessoa e por trecho (50 km por terra, 200 milhas no ar, 27 milhas
# náuticas no rio; mínimo 1) e, na volta, alimentação do par (meal_day no
# mesmo dia; meal_overnight por noite fora, menos as noites do PACIENTE
# internado). Valor = SIGTAP da competência do trecho + complemento da cidade.
RSpec.describe Tfd::Allowances do
  let!(:city) { transport_city!(tfd: true, billing: true) }
  let(:tfd) { tfd_case!(status: "authorized", destination: destination!(name: "Londrina", ibge: "4113700", km: 380)) }

  def leg(direction, on, mode: "bus_ticket", companion: false)
    result = Tfd::AddLeg.call(tfd_case: tfd.reload, by: committee!,
                              attrs: { "direction" => direction, "mode" => mode, "date" => on.iso8601,
                                       "ticket" => { "amount_cents" => 15_000, "carrier" => "Viação Garcia" }, "companion" => companion })
    raise "leg: #{result.reason} #{result.details}" if result.failure?

    result.payload[:leg]
  end

  def complete(row) = Tfd::CompleteLeg.call(leg: row, by: committee!)

  it "380 km por terra = 8 unidades de 50 km, por pessoa e por trecho, com o valor da tabela e o complemento" do
    Transport::SaveSettings.call(attrs: { "allowance_complements" => { "0803010125" => 105 } }, by: transport_admin!)
    out = leg("outbound", Date.current, companion: true)
    rows = complete(out).payload[:allowances]
    expect(rows.map { |r| [ r.person, r.kind, r.sigtap_code, r.quantity ] })
      .to contain_exactly([ "patient", "ground_km", "0803010125", 8 ], [ "companion", "ground_km", "0803010109", 8 ])
    patient_row = rows.find { |r| r.person == "patient" }
    expect([ patient_row.table_cents, patient_row.complement_cents, patient_row.total_cents ]).to eq([ 495, 105, 4800 ])
    companion_row = rows.find { |r| r.person == "companion" }
    expect([ companion_row.table_cents, companion_row.complement_cents, companion_row.total_cents ]).to eq([ 1000, 0, 8000 ])
    expect(patient_row.competence).to eq(Date.current.strftime("%Y%m"))
  end

  it "ida e volta no mesmo dia: meal_day; três noites fora: meal_overnight × 3" do
    out = leg("outbound", Date.current)
    complete(out)
    back = leg("return", Date.current)
    expect(back.outbound_leg_id).to eq(out.id)
    day = complete(back).payload[:allowances]
    expect(day.map { |r| [ r.person, r.kind, r.quantity ] }).to contain_exactly(%w[patient ground_km] + [ 8 ], %w[patient meal_day] + [ 1 ])

    out2 = leg("outbound", Date.current + 10)
    complete(out2)
    back2 = leg("return", Date.current + 13)
    expect(back2.outbound_leg_id).to eq(out2.id)
    meal = complete(back2).payload[:allowances].find { |r| r.kind == "meal_overnight" }
    expect([ meal.person, meal.quantity, meal.total_cents ]).to eq([ "patient", 3, 3000 ])
  end

  it "Review Focus 3: internado a estadia inteira — paciente sem diária, acompanhante com as noites; os dois com o deslocamento" do
    out = leg("outbound", Date.current + 10, companion: true)
    outbound_rows = complete(out).payload[:allowances]
    expect(outbound_rows.map { |r| [ r.person, r.kind ] }).to contain_exactly(%w[patient ground_km], %w[companion ground_km])
    stay = Tfd::RecordInpatient.call(tfd_case: tfd.reload, from: (Date.current + 10).iso8601, to: (Date.current + 15).iso8601, by: committee!)
    expect(stay).to be_ok
    back = leg("return", Date.current + 15, companion: true)
    rows = complete(back).payload[:allowances]
    meals = rows.select { |r| r.kind.start_with?("meal") }
    expect(meals.map { |r| [ r.person, r.kind, r.quantity ] }).to eq([ [ "companion", "meal_overnight", 5 ] ])
    expect(rows.reject { |r| r.kind.start_with?("meal") }.map { |r| [ r.person, r.kind ] })
      .to contain_exactly(%w[patient ground_km], %w[companion ground_km])
  end

  it "internação parcial e aberta: desconta só a interseção com [ida, volta); aberta conta até a volta; de um dia só não conta" do
    out = leg("outbound", Date.current + 10)
    complete(out)
    # [10, 10) = 0 noites; [12, …) aberta até a volta (14) = 2 noites.
    expect(Tfd::RecordInpatient.call(tfd_case: tfd.reload, from: (Date.current + 10).iso8601, to: (Date.current + 10).iso8601,
                                     by: committee!)).to be_ok
    expect(Tfd::RecordInpatient.call(tfd_case: tfd.reload, from: (Date.current + 12).iso8601, by: committee!)).to be_ok
    back = leg("return", Date.current + 14)
    meal = complete(back).payload[:allowances].find { |r| r.kind == "meal_overnight" }
    expect([ meal.person, meal.quantity ]).to eq([ "patient", 2 ]) # 4 noites − 2 internadas
  end

  it "aéreo em milhas (200) e fluvial em milhas náuticas (27), mínimo 1" do
    expect(described_class.units(TfdLeg.new(mode: "air", distance_km: 380))).to eq(2)    # 236 mi
    expect(described_class.units(TfdLeg.new(mode: "river", distance_km: 30))).to eq(1)   # 16,2 nm
    expect(described_class.units(TfdLeg.new(mode: "river", distance_km: 51))).to eq(2)   # 27,5 nm
    expect(described_class.units(TfdLeg.new(mode: "bus_ticket", distance_km: 51))).to eq(2)
    expect(described_class.units(TfdLeg.new(mode: "fleet", distance_km: 50))).to eq(1)
    expect(described_class.units(TfdLeg.new(mode: "fleet", distance_km: 0))).to eq(1)
  end

  it "o trecho aéreo vira air_miles; o fluvial, river_miles" do
    air = complete(leg("outbound", Date.current, mode: "air")).payload[:allowances]
    expect(air.map { |r| [ r.kind, r.sigtap_code, r.quantity ] }).to eq([ [ "air_miles", "0803010087", 2 ] ])
    river = complete(leg("return", Date.current + 1, mode: "river")).payload[:allowances]
    expect(river.map { |r| [ r.kind, r.sigtap_code ] }).to include([ "river_miles", "0803010117" ])
  end

  it "valor sem a SIGTAP da competência (nem anterior ativa) → tabela 0, só o complemento" do
    settings = TransportSetting.current
    settings.update!(allowance_complements: { "0803010125" => 50 })
    allow(Terminology::Sigtap).to receive(:release_for).and_return(nil)
    expect(described_class.value(code: "0803010125", on: Date.current, quantity: 3, settings: settings))
      .to eq(table_cents: 0, complement_cents: 50, total_cents: 150, competence: Date.current.strftime("%Y%m"))
  end

  it "volta sem ida aberta → no_outbound_leg; completar de novo → tfd_leg_done sem linha nova; recalcular não duplica" do
    result = Tfd::AddLeg.call(tfd_case: tfd, by: committee!, attrs: { "direction" => "return", "mode" => "bus_ticket", "date" => Date.current.iso8601,
                                                                       "ticket" => { "amount_cents" => 100, "carrier" => "X" } })
    expect(result.reason).to eq(:no_outbound_leg)
    expect(TfdLeg.count).to eq(0)

    out = leg("outbound", Date.current, companion: true)
    complete(out)
    back = leg("return", Date.current + 2, companion: true)
    complete(back)
    expect(TfdAllowance.count).to eq(6) # 2 × ground_km na ida, 2 × ground_km e 2 × meal_overnight na volta

    again = nil
    expect { again = complete(out.reload) }.not_to change(TfdAllowance, :count)
    expect(again.reason).to eq(:tfd_leg_done)
    expect { complete(back.reload) }.not_to(change { [ TfdAllowance.count, DomainEvent.where(name: "tfd.leg_done").count ] })
    # A corrida do fechamento com o botão: o cálculo rodado de novo não insere (ON CONFLICT DO NOTHING) e devolve as mesmas linhas.
    expect do
      expect(described_class.for_leg!(back.reload).map(&:id)).to match_array(back.tfd_allowances.where(kind: "ground_km").ids)
      expect(described_class.meals!(back).size).to eq(2)
    end.not_to change(TfdAllowance, :count)
  end

  it "a volta pareia com a ida aberta mais antiga com data ≤ a dela" do
    early = leg("outbound", Date.current + 1)
    late = leg("outbound", Date.current + 5)
    expect(leg("return", Date.current + 3).outbound_leg_id).to eq(early.id)
    expect(leg("return", Date.current + 6).outbound_leg_id).to eq(late.id)
    result = Tfd::AddLeg.call(tfd_case: tfd.reload, by: committee!, attrs: { "direction" => "return", "mode" => "bus_ticket",
                                                                              "date" => (Date.current + 7).iso8601,
                                                                              "ticket" => { "amount_cents" => 100, "carrier" => "X" } })
    expect(result.reason).to eq(:no_outbound_leg)
  end

  it "situações: primeiro trecho authorized → scheduled; primeira ida feita scheduled → travelling; eventos só com ids" do
    out = leg("outbound", Date.current)
    expect(tfd.reload.status).to eq("scheduled")
    expect(DomainEvent.where(name: "tfd.leg_added").map(&:payload)).to contain_exactly(
      { "tfd_case_id" => tfd.id, "tfd_leg_id" => out.id, "user_id" => an_instance_of(String) }
    )
    complete(out)
    expect(tfd.reload.status).to eq("travelling")
    expect(tfd.tfd_case_events.pluck(:kind)).to include("scheduled", "travelling")
    expect(DomainEvent.where(name: "tfd.leg_done").map(&:payload)).to eq([ { "tfd_leg_id" => out.id } ])
    expect(DomainEvent.where(name: "tfd.allowances_calculated")).to be_empty # só na volta, com refeição

    back = leg("return", Date.current + 1)
    complete(back)
    expect(DomainEvent.where(name: "tfd.allowances_calculated").map(&:payload))
      .to eq([ { "tfd_case_id" => tfd.id, "tfd_leg_id" => back.id } ])
  end
end
