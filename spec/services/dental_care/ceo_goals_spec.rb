require "rails_helper"

# Módulo 28 (ADR 0046; spec decisão 12; contrato §10, §16 O15/O24; Task 15):
# metas mensais do CEO por especialidade, composição e risco de suspensão.
RSpec.describe DentalCare::CeoGoals do
  let!(:city) { dental_city! }
  let(:ceo) { ceo_unit!(type: "II") }
  let(:dentist) { dentist!(ceo) }
  let(:october) { Date.new(2026, 10, 1) }
  let(:citizens) { Hash.new { |hash, key| hash[key] = verified_citizen!(hash.size + 1) } }

  # Perfil criado no mês dado (os meses anteriores não contam como falta).
  def profile_since!(unit, month) = unit.ceo_profile.update_columns(created_at: Time.zone.local(month.year, month.month, 1, 9))

  # Consulta odontológica finalizada no instante `at`, com os procedimentos
  # `{ sigtap => quantidade }` (linhas de até 32), gravada direto: rascunho,
  # itens e então a finalização.
  def finalized_with!(procedures, at:, unit: ceo, special_needs: false, baseline: false)
    by = unit == ceo ? dentist : dentist!(unit)
    consultation = dental_draft_row!(unit: unit, by: by, citizen: citizens[citizens.size], baseline: baseline)
    procedures.each do |code, quantity|
      quantity.divmod(32).then { |full, rest| Array.new(full, 32) + (rest.positive? ? [ rest ] : []) }.each do |qty|
        DentalProcedure.create!(consultation: consultation, patient_id: consultation.patient_id, procedure_code: code,
                                location_kind: "mouth", quantity: qty)
      end
    end
    consultation.update_columns(status: "finalized", finalized_at: at, care_type: baseline ? nil : 2, special_needs: special_needs)
    consultation
  end

  def in_month(month, day: 15) = Time.zone.local(month.year, month.month, day, 10)
  def goals(month = october, unit: ceo) = described_class.call(unit: unit, month: month)
  def specialty(result, key) = result.fetch(:specialties).find { |row| row.fetch(:key) == key }

  before { profile_since!(ceo, Date.new(2025, 1, 1)) }

  describe "endodontia (≥ 20% em dentes com 3+ raízes)" do
    it "CEO II, 60 endodontias com 12 de três raízes → meta atingida, 20.00" do
      finalized_with!({ "0307020053" => 12, "0307020061" => 48 }, at: in_month(october))
      expect(specialty(goals, "endodontics")).to eq(key: "endodontics", goal: 60, done: 60,
                                                    composition: { rule: "three_roots_min_20", ok: true, value: "20.00" }, met: true)
    end

    it "11 de três raízes → 18.33, não atingida mesmo com a quantidade" do
      finalized_with!({ "0307020053" => 11, "0307020061" => 49 }, at: in_month(october))
      expect(specialty(goals, "endodontics")).to include(done: 60, met: false,
                                                         composition: { rule: "three_roots_min_20", ok: false, value: "18.33" })
    end

    it "sem procedimento no grupo → composição { ok: false, value: \"0.00\" }" do
      expect(specialty(goals, "endodontics")).to eq(key: "endodontics", goal: 60, done: 0,
                                                    composition: { rule: "three_roots_min_20", ok: false, value: "0.00" }, met: false)
    end
  end

  describe "procedimentos básicos" do
    it "Review Focus 5: 120 básicos de pacientes sem necessidades especiais não contam" do
      finalized_with!({ "0307010031" => 120 }, at: in_month(october), special_needs: false)
      expect(specialty(goals, "basic")).to include(done: 0, met: false)
    end

    it "de paciente com necessidades especiais contam; 49% de restauração → composição não atingida" do
      finalized_with!({ "0307010031" => 49, "0101020074" => 51 }, at: in_month(october), special_needs: true)
      finalized_with!({ "0307010074" => 10 }, at: in_month(october), special_needs: false)
      expect(specialty(goals, "basic")).to eq(key: "basic", goal: 110, done: 100,
                                              composition: { rule: "restorations_min_50", ok: false, value: "49.00" }, met: false)
    end

    it "≥ 50% de restauração (sucessores contam) e quantidade → atingida" do
      finalized_with!({ "0307010031" => 30, "0307010120" => 30, "0101020074" => 50 }, at: in_month(october), special_needs: true)
      expect(specialty(goals, "basic")).to include(done: 110, met: true,
                                                   composition: { rule: "restorations_min_50", ok: true, value: "54.55" })
    end
  end

  it "periodontia e cirurgia sem regra de composição: met = done >= goal" do
    finalized_with!({ "0307030032" => 90, "0414020138" => 5 }, at: in_month(october), special_needs: false)
    finalized_with!({ "0414020278" => 89 }, at: in_month(october))
    result = goals
    expect(specialty(result, "periodontics")).to eq(key: "periodontics", goal: 90, done: 90, composition: nil, met: true)
    expect(specialty(result, "oral_surgery")).to eq(key: "oral_surgery", goal: 90, done: 89, composition: nil, met: false)
    expect(result.fetch(:specialties).map { |row| row.fetch(:key) }).to eq(%w[basic periodontics endodontics oral_surgery])
    expect(result.fetch(:ceo_type)).to eq("II")
  end

  it "o mês é o do fuso da cidade (23h do dia 31 em São Paulo é outubro)" do
    finalized_with!({ "0307030032" => 7 }, at: Time.utc(2026, 11, 1, 2, 0))
    finalized_with!({ "0307030032" => 5 }, at: Time.utc(2026, 10, 1, 2, 0)) # 30/09 23h em São Paulo
    expect(specialty(goals, "periodontics")).to include(done: 7)
  end

  it "registro inicial (baseline), rascunho e consulta de outra unidade não contam" do
    other = ceo_unit!(type: "II")
    finalized_with!({ "0307030032" => 30 }, at: in_month(october), unit: other)
    consultation = dental_draft_row!(unit: ceo, by: dentist, citizen: citizens[citizens.size])
    DentalProcedure.create!(consultation: consultation, patient_id: consultation.patient_id, procedure_code: "0307030032",
                            location_kind: "mouth", quantity: 30)
    baseline = finalized_with!({ "0307030032" => 30 }, at: in_month(october), baseline: true) # defesa: o registro inicial não leva procedimento
    expect(baseline.reload.baseline).to be(true)
    expect(specialty(goals, "periodontics")).to include(done: 0)
  end

  describe "faltas dos 12 meses fechados e risco de suspensão" do
    it "perio não atingida em agosto e setembro → { consecutive: 2, total: 2 } e risco em outubro sem meta" do
      profile_since!(ceo, Date.new(2026, 8, 1))
      result = goals
      expect(result.fetch(:misses_last_12).fetch("periodontics")).to eq(consecutive: 2, total: 2)
      expect(result.fetch(:suspension_risk)).to be(true)
    end

    it "faltas alternadas contam no total; o mês atingido zera a sequência" do
      { 7 => 90, 8 => 0, 9 => 90 }.each do |month, quantity|
        finalized_with!({ "0307030032" => quantity }, at: in_month(Date.new(2026, month, 1))) if quantity.positive?
      end
      profile_since!(ceo, Date.new(2026, 6, 1))
      expect(goals.fetch(:misses_last_12).fetch("periodontics")).to eq(consecutive: 0, total: 2) # junho e agosto
    end

    it "Review Focus 5: perfil criado em julho → janeiro a junho não contam como falta" do
      profile_since!(ceo, Date.new(2026, 7, 1))
      (7..9).each { |month| finalized_with!({ "0307030032" => 90 }, at: in_month(Date.new(2026, month, 1))) }
      result = goals
      expect(result.fetch(:misses_last_12).fetch("periodontics")).to eq(consecutive: 0, total: 0)
      expect(result.fetch(:misses_last_12).fetch("endodontics")).to eq(consecutive: 3, total: 3)
      expect(result.fetch(:history).map { |row| row.fetch(:month) }).to eq(%w[2026-07 2026-08 2026-09])
    end

    it "sem falta anterior e o mês não atingido → sem risco; mês atingido nunca tem risco" do
      profile_since!(ceo, Date.new(2026, 10, 1))
      expect(goals.fetch(:suspension_risk)).to be(false)
      profile_since!(ceo, Date.new(2026, 8, 1))
      finalized_with!({ "0307030032" => 90, "0414020278" => 90 }, at: in_month(october))
      finalized_with!({ "0307020053" => 12, "0307020061" => 48 }, at: in_month(october))
      finalized_with!({ "0307010031" => 60, "0101020074" => 50 }, at: in_month(october), special_needs: true)
      expect(goals.fetch(:suspension_risk)).to be(false)
    end

    it "history: os 12 meses fechados antes do mês, do mais antigo, com done e met por especialidade" do
      finalized_with!({ "0307030032" => 95 }, at: in_month(Date.new(2026, 9, 1)))
      history = goals.fetch(:history)
      expect(history.map { |row| row.fetch(:month) }).to eq((1..12).map { |back| (october << back).strftime("%Y-%m") }.reverse)
      expect(history.last).to eq(month: "2026-09", specialties: [
                                   { key: "basic", done: 0, met: false }, { key: "periodontics", done: 95, met: true },
                                   { key: "endodontics", done: 0, met: false }, { key: "oral_surgery", done: 0, met: false }
                                 ])
    end
  end

  it "só contagens: nada do paciente na resposta" do
    finalized_with!({ "0307030032" => 3 }, at: in_month(october))
    text = goals.to_json
    expect(text).not_to match(/patient|Maria|full_name|cpf|cns/i)
  end
end
