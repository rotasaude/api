require "rails_helper"

# Módulo 28, Task 14 (F-28.8): o marco c3_k do pré-natal é medido pela consulta
# odontológica finalizada de gestante, no CBO do dentista/TSB/ASB.
RSpec.describe "CareLines: oral_health source" do
  include ActiveSupport::Testing::TimeHelpers

  before do
    # SIGTAP e CIAP-2 imutáveis depois de ativas: as duas ordens de cidade juntas.
    dental_sigtap!
    ciap2_release!(ScreeningHelpers::CIAP2.merge(DentalHelpers::CIAP2).merge("W78" => "Gravidez"))
    care_city!
    dental_city!
  end

  let(:unit) { care_unit! }
  let(:doctor) { care_doctor!(unit) }
  let(:dentist) { dentist!(unit) }
  let(:team) { care_team!(unit, doctor) }
  let(:today) { Time.zone.today }
  let(:lmp) { today - 100 }
  let(:mom) { care_patient!(age: 27, sex: "female", problems: [ %w[ciap2 W78] ], unit: unit, doctor: doctor) }
  let(:citizen) { Citizen.find_by!(patient_id: mom.id) }
  let(:enrollment) { care_enrollment!(patient: mom, line: adopted_line!("pregnancy_c3"), team: team, by: doctor, anchor_date: lmp) }

  def c3_k = CareLines::Evaluation.enrollments([ enrollment ], today: today).fetch(enrollment.id).practices.find { |p| p.key == "c3_k" }

  def dental!(pregnant: true, **opts) = finalized_dental!(unit: unit, by: dentist, citizen: citizen, dental: { pregnant: pregnant }, **opts)

  it "consulta odontológica finalizada de gestante cumpre o c3_k" do
    expect(c3_k).to have_attributes(status: "ok", tracked: true, met: false, count: 0)
    dental!
    expect(c3_k).to have_attributes(status: "ok", tracked: true, met: true, count: 1)
  end

  it "gestante falsa não conta" do
    dental!(pregnant: false)
    expect(c3_k).to have_attributes(tracked: true, met: false, count: 0)
  end

  it "registro inicial (baseline) não conta" do
    consultation = dental_consultation!(unit: unit, by: dentist, citizen: citizen, baseline: true)
    body = { "dental" => { "pregnant" => true, "findings" => [ { "tooth" => 16, "situation" => "caries" } ] } }
    expect(Consultations::SaveDraft.call(consultation: consultation, params: body, by: dentist)).to be_ok
    expect(Consultations::Finalize.call(consultation: consultation.reload, outcome_params: { "outcome" => "discharged" }, by: dentist)).to be_ok
    expect(consultation.reload).to have_attributes(status: "finalized", baseline: true)
    expect(c3_k).to have_attributes(met: false, count: 0)
  end

  it "rascunho não conta" do
    dental_consultation!(unit: unit, by: dentist, citizen: citizen)
    expect(c3_k).to have_attributes(met: false, count: 0)
  end

  context "com a DUM depois da consulta" do
    let(:lmp) { today + 2 }

    it "a consulta anterior à DUM fica fora da janela" do
      dental!
      expect(c3_k).to have_attributes(tracked: true, met: false, count: 0)
    end
  end

  it "a consulta odontológica não conta no marco de consulta médica/enfermagem" do
    enrollment
    dental!
    consultation = CareLines::Sources.load(patient_ids: [ mom.id ], sources: %w[consultation oral_health], since: today - 200).fetch(mom.id)
    expect(consultation["oral_health"].size).to eq(1)
    expect(consultation["oral_health"].first.cbo).to start_with("2232")
    expect(consultation.fetch("consultation", []).map(&:cbo)).to all(satisfy { |cbo| !cbo.start_with?("2232") })
    expect(CareLines::Evaluation.enrollments([ enrollment ], today: today).fetch(enrollment.id).practices.find { |p| p.key == "c3_a" })
      .to have_attributes(met: false)
  end

  it "a consulta médica não conta como saúde bucal" do
    finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    expect(c3_k).to have_attributes(met: false, count: 0)
  end

  it "cbo_filter só vale para consultation e oral_health" do
    base = { "key" => "c3_k", "label" => "x", "anchor" => "lmp", "window_days" => 294, "min_count" => 1, "schedule" => "end_of_window",
             "points" => 100, "cbo_filter" => %w[2232] }
    expect(CareLines::Rules.practices([ base.merge("source" => "oral_health") ], template: true)).to be_ok
    expect(CareLines::Rules.practices([ base.merge("source" => "acs_visit") ], template: true)).to be_failure
  end

  it "o catálogo-base traz c3_k rastreado e filtrado pelo CBO odontológico" do
    entry = CareLines::Templates::Load.entries.find { |e| e["key"] == "pregnancy_c3" }
    practice = entry["practices"].find { |p| p["key"] == "c3_k" }
    expect(practice).to include("source" => "oral_health", "cbo_filter" => %w[2232 3224])
    expect(CareLines::Catalog.untracked?("oral_health")).to be(false)
    expect(CareLines::Catalog.untracked?("acs_visit")).to be(true)
  end
end
