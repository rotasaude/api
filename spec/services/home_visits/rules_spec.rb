require "rails_helper"

# Módulo 24b (ADR 0052; contrato §3, §13, §16 Q21, Q34–Q36, Q40, Q44): as regras
# puras da visita. Recebem o corpo efetivo (o `subject` já derivado pelo
# HomeVisits::Record) e os fatos já lidos (domicílio, microárea, família, pessoa),
# nunca o banco. Devolvem [] ou [{ error:, path: }] com o primeiro problema.
RSpec.describe HomeVisits::Rules, type: :model do
  let(:today) { Date.new(2026, 11, 12) }
  let(:now) { Time.zone.local(2026, 11, 12, 15, 0) }

  def area(active: true) = described_class::AreaFacts.new(id: SecureRandom.uuid, active: active)

  def household(property_type: "1", active: true, active_families: true)
    described_class::HouseholdFacts.new(id: SecureRandom.uuid, active: active, property_type: property_type,
                                        active_families: active_families)
  end

  def family(household_id:, moved_out: false, responsible_exited: false)
    described_class::FamilyFacts.new(id: SecureRandom.uuid, household_id: household_id, moved_out: moved_out,
                                     responsible_exited: responsible_exited)
  end

  def person(sex: "female", household_id: nil) = described_class::PersonFacts.new(sex: sex, household_id: household_id)

  # Visita realizada ao imóvel residencial fora de área, sem pessoa e sem motivo.
  def input(**over)
    { "occurred_at" => Time.zone.local(2026, 11, 12, 9, 0), "out_of_area" => true, "property_type" => "1", "subject" => "none",
      "outcome" => 1, "reasons" => [], "shared" => false }.merge(over.stringify_keys)
  end

  def check(body = input, household: nil, family: nil, patient: nil, micro_area: nil)
    described_class.check(body, household: household, family: family, patient: patient, today: today, now: now,
                                micro_area: micro_area)
  end

  def error(code, path) = [ { error: code, path: path } ]

  it "o corpo mínimo passa" do
    expect(check).to eq([])
  end

  it "turno 11:59 → 1, 12:00 → 2, 18:00 → 3, no fuso da cidade" do
    Time.use_zone("America/Sao_Paulo") do
      expect(described_class.shift(Time.utc(2026, 11, 12, 14, 59))).to eq(1) # 11:59 local
      expect(described_class.shift(Time.utc(2026, 11, 12, 15, 0))).to eq(2)  # 12:00 local
      expect(described_class.shift(Time.utc(2026, 11, 12, 20, 59))).to eq(2) # 17:59 local
      expect(described_class.shift(Time.utc(2026, 11, 12, 21, 0))).to eq(3)  # 18:00 local
    end
    Time.use_zone("America/Rio_Branco") do
      expect(described_class.shift(Time.utc(2026, 11, 12, 16, 59))).to eq(1) # 11:59 no Acre
    end
  end

  it "data futura e data além do prazo do SIAPS → visit_date_out_of_range (path occurred_at)" do
    expect(check(input(occurred_at: now + 1.minute))).to eq(error(:visit_date_out_of_range, "occurred_at"))
    first = described_class.min_date(today)
    expect(Ledi::Deadline.on((first - 1).strftime("%Y%m"))).to be <= today
    expect(check(input(occurred_at: (first - 1).in_time_zone.change(hour: 10)))).to eq(error(:visit_date_out_of_range, "occurred_at"))
    expect(check(input(occurred_at: first.in_time_zone.change(hour: 10)))).to eq([])
    expect(check(input(occurred_at: "2026-11-12T09:00:00-03:00"))).to eq(error(:invalid_home_visit, "occurred_at"))
  end

  it "com domicílio, mandar property_type (ou microárea, ou fora de área) → invalid_home_visit no campo" do
    home = household
    base = input(household_id: home.id, out_of_area: nil, property_type: nil)
    expect(check(base, household: home, micro_area: area)).to eq([])
    expect(check(base.merge("property_type" => "1"), household: home, micro_area: area)).to eq(error(:invalid_home_visit, "property_type"))
    expect(check(base.merge("micro_area_id" => SecureRandom.uuid), household: home, micro_area: area))
      .to eq(error(:invalid_home_visit, "micro_area_id"))
    expect(check(base.merge("out_of_area" => true), household: home, micro_area: area)).to eq(error(:invalid_home_visit, "out_of_area"))
  end

  it "sem domicílio: property_type obrigatório e microárea xor fora de área" do
    expect(check(input(property_type: nil))).to eq(error(:invalid_home_visit, "property_type"))
    expect(check(input(property_type: 1))).to eq(error(:invalid_home_visit, "property_type"))
    expect(check(input(out_of_area: nil))).to eq(error(:invalid_home_visit, "micro_area_id"))
    expect(check(input(micro_area_id: SecureRandom.uuid), micro_area: area)).to eq(error(:invalid_home_visit, "out_of_area"))
    expect(check(input(out_of_area: nil, micro_area_id: SecureRandom.uuid), micro_area: area)).to eq([])
  end

  it "domicílio inativo → household_inactive; microárea inativa (herdada ou escolhida) → micro_area_inactive (Q21)" do
    inactive = household(active: false)
    expect(check(input(household_id: inactive.id, out_of_area: nil, property_type: nil), household: inactive, micro_area: area))
      .to eq(error(:household_inactive, "household_id"))
    home = household
    expect(check(input(household_id: home.id, out_of_area: nil, property_type: nil), household: home, micro_area: area(active: false)))
      .to eq(error(:micro_area_inactive, "household_id"))
    expect(check(input(out_of_area: nil, micro_area_id: SecureRandom.uuid), micro_area: area(active: false)))
      .to eq(error(:micro_area_inactive, "micro_area_id"))
  end

  it "não residencial com patient_id (ou família, ou paciente novo, ou subject) → non_residential_with_person" do
    commercial = input(property_type: "2")
    expect(check(commercial)).to eq([])
    expect(check(commercial.merge("subject" => "resident", "patient_id" => SecureRandom.uuid), patient: person))
      .to eq(error(:non_residential_with_person, "patient_id"))
    expect(check(commercial.merge("family_id" => SecureRandom.uuid))).to eq(error(:non_residential_with_person, "family_id"))
    expect(check(commercial.merge("new_patient" => { "full_name" => "X" }))).to eq(error(:non_residential_with_person, "new_patient"))
    expect(check(commercial.merge("subject" => "resident"))).to eq(error(:non_residential_with_person, "subject"))
  end

  it "não residencial só aceita 1 27 28 31 34 35 36 37, e sem medidas" do
    allowed = [ 1, 27, 28, 31, 34, 35, 36, 37 ]
    expect(check(input(property_type: "12", reasons: allowed))).to eq([])
    expect(check(input(property_type: "12", reasons: [ 1, 29 ]))).to eq(error(:reason_not_allowed, "reasons[1]"))
    expect(check(input(property_type: "12", measurements: { "temperature_c" => 36.5 })))
      .to eq(error(:measurements_forbidden, "measurements"))
  end

  it "residencial sem pessoa: só 1 27 28 e sem peso/altura (Q34/Q40)" do
    expect(check(input(reasons: [ 1, 27, 28 ], measurements: { "temperature_c" => 36.5 }))).to eq([])
    home = household
    at_home = input(household_id: home.id, out_of_area: nil, property_type: nil, reasons: [ 1, 31 ])
    expect(check(at_home, household: home, micro_area: area)).to eq(error(:reason_not_allowed, "reasons[1]"))
    expect(check(input(measurements: { "temperature_c" => 36.5, "height_cm" => 160 })))
      .to eq(error(:measurements_forbidden, "measurements.height_cm"))
    expect(check(input(measurements: { "weight_kg" => 70 }))).to eq(error(:measurements_forbidden, "measurements.weight_kg"))
  end

  it "residencial sem pessoa com 29/34–37: recusado com família ativa; aceito sem família ativa (Q40, Q44)" do
    with_family = household(active_families: true)
    body = ->(home) { input(household_id: home.id, out_of_area: nil, property_type: nil, reasons: [ 34, 29 ]) }
    expect(check(body.(with_family), household: with_family, micro_area: area)).to eq(error(:reason_not_allowed, "reasons[0]"))
    empty = household(active_families: false)
    expect(check(body.(empty), household: empty, micro_area: area)).to eq([])
    expect(check(input(reasons: [ 29, 35 ]))).to eq([]) # sem domicílio: sem cadastro de família
  end

  it "masculino com motivo 5 → reason_not_allowed path reasons[0]; feminino, sem sexo e sem pessoa não (Q35)" do
    resident = input(subject: "resident", patient_id: SecureRandom.uuid, reasons: [ 5, 11 ])
    expect(check(resident, patient: person(sex: "male"))).to eq(error(:reason_not_allowed, "reasons[0]"))
    expect(check(resident.merge("reasons" => [ 11, 6 ]), patient: person(sex: "male"))).to eq(error(:reason_not_allowed, "reasons[1]"))
    expect(check(resident, patient: person(sex: "female"))).to eq([])
    expect(check(resident, patient: person(sex: nil))).to eq([])
  end

  it "recusa com motivo → reasons_forbidden; ausente com peso → measurements_forbidden" do
    resident = input(subject: "resident", patient_id: SecureRandom.uuid)
    expect(check(resident.merge("outcome" => 2, "reasons" => [ 11 ]), patient: person)).to eq(error(:reasons_forbidden, "reasons"))
    expect(check(resident.merge("outcome" => 3, "measurements" => { "weight_kg" => 70 }), patient: person))
      .to eq(error(:measurements_forbidden, "measurements"))
    expect(check(resident.merge("outcome" => 3), patient: person)).to eq([])
  end

  it "motivos: lista de códigos do dicionário, sem repetição, no máximo 36 (Q36)" do
    resident = input(subject: "resident", patient_id: SecureRandom.uuid)
    expect(check(resident.merge("reasons" => "11"), patient: person)).to eq(error(:invalid_home_visit, "reasons"))
    expect(check(resident.merge("reasons" => [ 11, 26 ]), patient: person)).to eq(error(:invalid_home_visit, "reasons[1]"))
    expect(check(resident.merge("reasons" => [ 11, 11 ]), patient: person)).to eq(error(:invalid_home_visit, "reasons[1]"))
    expect(check(resident.merge("reasons" => [ "11" ]), patient: person)).to eq(error(:invalid_home_visit, "reasons[0]"))
    expect(check(resident.merge("reasons" => [ 11 ] * 37), patient: person)).to eq(error(:invalid_home_visit, "reasons"))
  end

  it "sistólica sem diastólica e glicemia sem tipo → invalid_home_visit no campo que falta" do
    resident = input(subject: "resident", patient_id: SecureRandom.uuid)
    expect(check(resident.merge("measurements" => { "systolic" => 120 }), patient: person))
      .to eq(error(:invalid_home_visit, "measurements.diastolic"))
    expect(check(resident.merge("measurements" => { "glucose_type" => 0 }), patient: person))
      .to eq(error(:invalid_home_visit, "measurements.glucose_mg_dl"))
    expect(check(resident.merge("measurements" => { "systolic" => 120, "diastolic" => 80, "glucose_mg_dl" => 99, "glucose_type" => 0 }),
                 patient: person)).to eq([])
  end

  it "peso 0.4 → invalid_home_visit path measurements.weight_kg; faixas e casas do YAML" do
    resident = input(subject: "resident", patient_id: SecureRandom.uuid)
    at = ->(measurements) { check(resident.merge("measurements" => measurements), patient: person) }
    expect(at.({ "weight_kg" => 0.4 })).to eq(error(:invalid_home_visit, "measurements.weight_kg"))
    expect(at.({ "weight_kg" => 0.4996 })).to eq([]) # 3 casas → 0.5
    expect(at.({ "weight_kg" => "70" })).to eq(error(:invalid_home_visit, "measurements.weight_kg"))
    expect(at.({ "temperature_c" => 45.1 })).to eq(error(:invalid_home_visit, "measurements.temperature_c"))
    expect(at.({ "glucose_mg_dl" => 90, "glucose_type" => 4 })).to eq(error(:invalid_home_visit, "measurements.glucose_type"))
    expect(at.({ "bmi" => 22 })).to eq(error(:invalid_home_visit, "measurements.bmi"))
    expect(at.([ 70 ])).to eq(error(:invalid_home_visit, "measurements"))
    expect(described_class.measurements("weight_kg" => 70.12345, "height_cm" => 160.06, "systolic" => 120.4, "diastolic" => 80))
      .to eq("weight_kg" => 70.123, "height_cm" => 160.1, "systolic" => 120, "diastolic" => 80)
    expect(described_class.measurements({})).to be_nil
  end

  it "observação com 501 code points → recusada, nunca cortada; 500 depois do strip passam" do
    expect(check(input(note: "  #{'é' * 500}  "))).to eq([])
    expect(check(input(note: "😀" * 501))).to eq(error(:invalid_home_visit, "note"))
    expect(check(input(note: 12))).to eq(error(:invalid_home_visit, "note"))
    expect(described_class.note("  #{'é' * 500}  ")).to eq("é" * 500)
    expect(described_class.note("   ")).to be_nil
  end

  it "paciente com cadastro ativo em outro domicílio → patient_in_other_household; no mesmo ou sem cadastro, passa" do
    home = household
    resident = input(household_id: home.id, out_of_area: nil, property_type: nil, subject: "resident", patient_id: SecureRandom.uuid)
    expect(check(resident, household: home, micro_area: area, patient: person(household_id: SecureRandom.uuid)))
      .to eq(error(:patient_in_other_household, "patient_id"))
    expect(check(resident, household: home, micro_area: area, patient: person(household_id: home.id))).to eq([])
    expect(check(resident, household: home, micro_area: area, patient: person(household_id: nil))).to eq([])
  end

  it "resident exige exatamente um de patient_id e new_patient, sem family_id" do
    resident = input(subject: "resident")
    expect(check(resident, patient: person)).to eq(error(:invalid_home_visit, "patient_id"))
    expect(check(resident.merge("patient_id" => SecureRandom.uuid, "family_id" => SecureRandom.uuid), patient: person))
      .to eq(error(:invalid_home_visit, "family_id"))
    expect(check(resident.merge("new_patient" => { "sex" => "female" }), patient: person)).to eq([])
  end

  it "família com responsável que saiu → family_without_responsible; família em mudança → family_moved_out (Q21)" do
    home = household
    body = input(household_id: home.id, out_of_area: nil, property_type: nil, subject: "family_responsible", reasons: [ 29 ])
    ok = family(household_id: home.id)
    expect(check(body.merge("family_id" => ok.id), household: home, family: ok, micro_area: area, patient: person)).to eq([])
    exited = family(household_id: home.id, responsible_exited: true)
    expect(check(body.merge("family_id" => exited.id), household: home, family: exited, micro_area: area, patient: person))
      .to eq(error(:family_without_responsible, "family_id"))
    moved = family(household_id: home.id, moved_out: true)
    expect(check(body.merge("family_id" => moved.id), household: home, family: moved, micro_area: area, patient: person))
      .to eq(error(:family_moved_out, "family_id"))
  end

  it "family_responsible exige domicílio e a família dele, sem patient_id" do
    home = household
    body = input(household_id: home.id, out_of_area: nil, property_type: nil, subject: "family_responsible")
    expect(check(body, household: home, micro_area: area)).to eq(error(:invalid_home_visit, "family_id"))
    other = family(household_id: SecureRandom.uuid)
    expect(check(body.merge("family_id" => other.id), household: home, family: other, micro_area: area, patient: person))
      .to eq(error(:invalid_home_visit, "family_id"))
    mine = family(household_id: home.id)
    expect(check(body.merge("family_id" => mine.id, "patient_id" => SecureRandom.uuid), household: home, family: mine,
                                                                                   micro_area: area, patient: person))
      .to eq(error(:invalid_home_visit, "patient_id"))
    expect(check(input(subject: "family_responsible", family_id: mine.id), family: mine, patient: person))
      .to eq(error(:invalid_home_visit, "household_id"))
  end

  it "desfecho, subject, shared e out_of_area fora do domínio → invalid_home_visit" do
    expect(check(input(outcome: 4))).to eq(error(:invalid_home_visit, "outcome"))
    expect(check(input(outcome: "1"))).to eq(error(:invalid_home_visit, "outcome"))
    expect(check(input(subject: "neighbor"))).to eq(error(:invalid_home_visit, "subject"))
    expect(check(input(shared: "yes"))).to eq(error(:invalid_home_visit, "shared"))
    expect(check(input(out_of_area: "true"))).to eq(error(:invalid_home_visit, "out_of_area"))
    expect(check(input(subject: "none", patient_id: SecureRandom.uuid))).to eq(error(:invalid_home_visit, "patient_id"))
  end

  it "fatos e o resultado nunca mostram sexo nem documento no inspect" do
    expect(person(sex: "male").inspect).not_to include("male")
    expect(person(sex: "male").to_s).not_to include("male")
  end
end
