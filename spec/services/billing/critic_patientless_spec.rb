require "rails_helper"

# BPA-C sem paciente (ADR 0049; contrato §8 e §15 P2; plano, Desvio 11; Review
# Focus 5): a linha da ação de equipe do CAPS não tem paciente. A crítica não
# cobra paciente no BPA-C; no BPA-I (ou se o código virou BPA-I) cobra a
# identificação, e a linha nunca chega ao arquivo. O recálculo do fechamento
# que tira o `01` do código regrava o instrumento (not_bpa) sem estourar o
# CHECK; o arquivo não leva a linha. Linhas, JSON, pendências e resumo não
# quebram sem paciente; a idade do BPA-C sem paciente é 0 (gate do layout).
RSpec.describe "Billing — BPA-C sem paciente" do
  let!(:city) { psychosocial_city!(billing: true) }
  let(:caps) { caps! }
  let(:staff) { caps_staff!(caps, cbo: "251510") }
  let(:clerk) { billing_clerk! }
  let(:establishment) { Billing::Establishment.for_unit(caps) }

  def facts(**over)
    Billing::Critic::Facts.new(**{ establishment: establishment, sigtap_code: "0301080313", performed_on: Time.zone.today, cbo_code: "251510",
                                   professional_cns: nil, cid10: nil, patient: nil }.merge(over))
  end

  # Linha sem paciente gravada direto, como se a SIGTAP da competência ainda
  # listasse o `01` do código no dia da gravação (o caminho real é
  # Billing::FromPsychosocial, que lê a SIGTAP de hoje).
  def patientless_line!(code, on:, period:, cbo: "251510")
    raw_procedure!(unit: caps, patient: nil, professional: staff, source: "psychosocial", recorded_by_user: nil,
                   psychosocial_action: record_action!(caps, staff, sigtap_code: "0301080313"), sigtap_code: code, cid10: nil,
                   cbo_code: cbo, instrument: "bpa_c", performed_on: on, billing_period: period, billing_competence: period.competence)
  end

  # Release SIGTAP de uma competência antiga em que o 0301080305 perdeu o
  # `01` (só RAAS) e o 0301080313 o mantém.
  def release_without_bpa_c!(competence)
    release = TerminologyRelease.create!(kind: "sigtap", version: competence, source_sha256: "c" * 64, imported_by: "rspec",
                                         imported_at: Time.current, status: "importing")
    { "0301080305" => "09", "0301080313" => "01" }.each do |code, instrument|
      SigtapProcedure.create!(release: release, code: code, name: "PROCEDIMENTO #{code}")
      SigtapProcedureInstrument.create!(release: release, procedure_code: code, instrument_code: instrument, instrument_name: "TESTE")
      SigtapProcedureCbo.create!(release: release, procedure_code: code, cbo_code: "251510")
    end
    release.update!(status: "active", activated_at: Time.current)
  end

  describe Billing::Critic do
    it "BPA-C sem paciente: nenhum motivo de paciente, faturável" do
      expect(Billing::Critic.call(facts)).to have_attributes(instrument: "bpa_c", billable: true, reasons: [])
      expect(Billing::Critic.call(facts, closing: true)).to have_attributes(instrument: "bpa_c", billable: true, reasons: [])
    end

    it "BPA-I sem paciente: missing_patient_id (o arquivo nunca o leva)" do
      outcome = Billing::Critic.call(facts(sigtap_code: "0301080232", professional_cns: "798312812760829"), closing: true)
      expect(outcome).to have_attributes(instrument: "bpa_i", billable: false)
      expect(outcome.reasons).to include("missing_patient_id")
    end
  end

  it "Review Focus 5: o fechamento recalcula a linha BPA-C sem paciente cujo código perdeu o 01 → not_bpa, fora do arquivo, sem erro" do
    competence = (Time.zone.today << 2).strftime("%Y%m")
    release_without_bpa_c!(competence)
    on = Date.strptime(competence, "%Y%m") + 9
    billing_settings!
    period, = Billing::Periods.assign!(establishment, competence)
    lost = patientless_line!("0301080305", on: on, period: period)
    kept = patientless_line!("0301080313", on: on, period: period)

    result = Billing::Close.call(period: period, by: clerk)

    expect(result).to be_ok
    expect(lost.reload).to have_attributes(instrument: "not_bpa", billable: false, patient_id: nil, billing_export_id: nil)
    expect(lost.blocking_reasons).to include("not_bpa_instrument")
    expect(kept.reload).to have_attributes(instrument: "bpa_c", billable: true, billing_export_id: result.payload[:export].id)
    export = result.payload[:export]
    expect(export).to have_attributes(lines_bpa_c: 1, lines_bpa_i: 0)
    expect(export.file).to include("0301080313")
    expect(export.file).not_to include("0301080305")
    expect(Billing::Summary.call(period.reload)).to include(bpa_c_lines: 1, bpa_i_lines: 0)
  end

  it "Lines.build: o BPA-C sem paciente sai com idade 0" do
    period, = Billing::Periods.assign!(establishment, Time.zone.today.strftime("%Y%m"))
    line = patientless_line!("0301080313", on: Time.zone.today, period: period)
    c_lines = nil
    allow(Billing::BpaFile).to receive(:build).and_wrap_original do |original, **kwargs|
      c_lines = kwargs[:c_lines]
      original.call(**kwargs)
    end
    Billing::Lines.build(period: period, establishment: establishment, procedures: [ line ], settings: billing_settings!)
    expect(c_lines).to eq([ Billing::BpaFile::CLine.new(cnes: caps.cnes, competence: Time.zone.today.strftime("%Y%m"), cbo: "251510",
                                                        procedure: "0301080313", age: Billing::Lines::PATIENTLESS_AGE, quantity: 1) ])
    expect(Billing::Lines::PATIENTLESS_AGE).to eq(0)
  end

  it "pendências, resumo e JSON: patient nulo, sem quebrar" do
    period, = Billing::Periods.assign!(establishment, Time.zone.today.strftime("%Y%m"))
    blocked = patientless_line!("0301080313", on: Time.zone.today, period: period, cbo: "515105")
    items = Billing::Pending.call(period)
    expect(items.map { |item| item[:procedure_id] }).to eq([ blocked.id ])
    expect(items.first).to include(patient: nil, reasons: %w[cbo_not_allowed], fix: "procedure")
    expect(Billing::Summary.call(period)).to include(pending: 1, not_billable: { "cbo_not_allowed" => 1 })
    expect(Billing::Json.procedure(blocked)).to include(patient: nil, source_ref: { type: "psychosocial_action", id: blocked.psychosocial_action_id })
    expect(Billing::Json.procedures([ blocked ]).first[:patient]).to be_nil
  end
end
