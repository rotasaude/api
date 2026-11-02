require "rails_helper"

# Módulo 29, Task 5 (ADR 0047; Desvios 10 e 11): a situação vacinal
# materializada por paciente × série (cópia recalculável, DELETE + INSERT) e a
# conferência born_after_go_live gravada pelo sistema.
RSpec.describe Vaccination::Statuses do
  let!(:city) { vaccination_city! }
  let(:today) { Date.new(2026, 11, 2) }
  def go_live!(on) = VaccinationSetting.current.update!(go_live_on: on)
  def rows(patient) = VaccinationStatus.where(patient_id: patient.id).index_by(&:series)

  it "nascido em ou depois do go-live: grava a conferência born_after_go_live uma vez e as linhas saem checked" do
    go_live!(today - 365)
    baby = vaccine_patient!(birth_date: today - 90)
    expect { 2.times { described_class.refresh!(baby, today: today) } }.to change(VaccinationRecordCheck, :count).by(1)
    check = VaccinationRecordCheck.find_by!(patient_id: baby.id)
    expect(check).to have_attributes(mode: "born_after_go_live", checked_by_user_id: nil, vaccine_room_id: nil)
    expect(described_class.checked?(baby.id)).to be(true)
    expect(rows(baby).values.map(&:checked)).to all(be(true))
    expect(rows(baby)["penta"]).to have_attributes(status: "overdue", next_dose_code: "1", due_on: today - 30, doses_applied: 0,
                                                    immunobiological_code: "42", computed_on: today)
  end

  it "nascido antes do go-live, ou go-live em branco: nenhuma conferência; linhas checked false; nenhum overdue" do
    older = vaccine_patient!(birth_date: today - 365)
    described_class.refresh!(older, today: today)
    go_live!(today - 30)
    described_class.refresh!(older, today: today)
    expect(VaccinationRecordCheck.where(patient_id: older.id)).to be_empty
    expect(rows(older).values.map(&:checked)).to all(be(false))
    expect(rows(older).values.map(&:status)).not_to include("overdue")
    expect(rows(older)["penta"].status).to eq("unchecked")
  end

  it "DELETE + INSERT: a dose registrada troca a linha; not_applicable não é gravada" do
    go_live!(today - 365)
    baby = vaccine_patient!(birth_date: today - 120)
    described_class.refresh!(baby, today: today)
    expect(rows(baby)).not_to have_key("hepb_birth") # 30 dias passados sem a dose
    expect(rows(baby)["penta"].next_dose_code).to eq("1")
    create_immunization!(vaccine_room!, patient: baby, applied_at: (today - 50).in_time_zone.change(hour: 10))
    described_class.refresh!(baby, today: today)
    expect(rows(baby)["penta"]).to have_attributes(next_dose_code: "2", doses_applied: 1, status: "upcoming", due_on: today + 10)
    expect(VaccinationStatus.where(patient_id: baby.id, series: "penta").count).to eq(1)
  end

  it "dose cancelada não conta" do
    go_live!(today - 365)
    baby = vaccine_patient!(birth_date: today - 120)
    room = vaccine_room!
    dose = create_immunization!(room, patient: baby, applied_at: (today - 50).in_time_zone.change(hour: 10))
    dose.update_columns(cancelled_at: Time.current, cancelled_by_user_id: dose.vaccinator_user_id, cancel_reason: "dose registrada por engano")
    described_class.refresh!(baby, today: today)
    expect(rows(baby)["penta"]).to have_attributes(next_dose_code: "1", doses_applied: 0)
  end

  it "paciente sem nascimento: nenhuma linha (e as antigas saem)" do
    patient = vaccine_patient!(birth_date: today - 400)
    described_class.refresh!(patient, today: today)
    expect(rows(patient)).not_to be_empty
    patient.update_columns(birth_date: nil)
    described_class.refresh!(patient.reload, today: today)
    expect(rows(patient)).to be_empty
  end

  it "age_months = meses completos em today" do
    patient = vaccine_patient!(birth_date: Date.new(2025, 11, 3))
    described_class.refresh!(patient, today: today)
    expect(rows(patient).values.map(&:age_months).uniq).to eq([ 11 ])
    described_class.refresh!(patient, today: Date.new(2026, 11, 3))
    expect(rows(patient).values.map(&:age_months).uniq).to eq([ 12 ])
    jan31 = vaccine_patient!(birth_date: Date.new(2026, 1, 31))
    described_class.refresh!(jan31, today: Date.new(2026, 2, 28))
    expect(rows(jan31).values.map(&:age_months).uniq).to eq([ 0 ])
  end

  it "gestante: dTpa pela DUM da inscrição ativa na linha de pré-natal" do
    care_lines_loaded!
    unit = create_unit("UBS Pré-natal #{SecureRandom.hex(2)}")
    nurse = screener!(unit, cbo: "223505")
    team = HealthTeam.create!(health_unit: unit, ine: format("%010d", SecureRandom.random_number(10**10)), kind: "70", name: "ESF Pré-natal")
    mother = vaccine_patient!(birth_date: Date.new(1996, 5, 1))
    described_class.refresh!(mother, today: today)
    expect(rows(mother)).not_to have_key("dtpa_pregnancy")
    care_enrollment!(patient: mother, line: adopted_line!("pregnancy_c3"), team: team, by: nurse, anchor_date: Date.new(2026, 6, 1))
    expect(described_class.pregnant_since(mother)).to eq(Date.new(2026, 6, 1))
    described_class.refresh!(mother, today: today)
    expect(rows(mother)["dtpa_pregnancy"]).to have_attributes(due_on: Date.new(2026, 10, 19), immunobiological_code: "57")
  end
end
