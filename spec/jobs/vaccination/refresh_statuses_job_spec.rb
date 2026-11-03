require "rails_helper"

# Módulo 29, Task 5 (ADR 0047, Desvio 11): recálculo diário da situação
# vacinal materializada, por cidade com a sala de vacina utilizável.
RSpec.describe Vaccination::RefreshStatusesJob do
  let!(:city) { vaccination_city! }
  after { Current.reset }

  def run! = described_class.perform_now

  it "recalcula todos os pacientes com nascimento; sem nascimento, nenhuma linha" do
    baby = vaccine_patient!(birth_date: Time.zone.today - 70)
    adult = vaccine_patient!(birth_date: Time.zone.today - 40.years)
    unknown = vaccine_patient!(birth_date: Time.zone.today - 70)
    unknown.update_columns(birth_date: nil)
    VaccinationStatus.create!(patient: unknown, series: "penta", immunobiological_code: "42", status: "due", age_months: 2, computed_on: Time.zone.today - 1)
    run!
    expect(VaccinationStatus.where(patient_id: baby.id).pluck(:series)).to include("penta")
    expect(VaccinationStatus.where(patient_id: adult.id).pluck(:series)).to include("dt_adult")
    expect(VaccinationStatus.where(patient_id: unknown.id)).to be_empty
    expect(VaccinationStatus.distinct.pluck(:computed_on)).to eq([ Time.use_zone(city.time_zone) { Time.zone.today } ])
  end

  it "lê o go-live uma vez por execução para N pacientes, com o mesmo resultado (born_after_go_live)" do
    VaccinationSetting.current.update!(go_live_on: Time.zone.today - 200)
    after = 3.times.map { vaccine_patient!(birth_date: Time.zone.today - 100) }
    before = vaccine_patient!(birth_date: Time.zone.today - 400)
    allow(VaccinationSetting).to receive(:current).and_call_original
    run!
    expect(VaccinationSetting).to have_received(:current).once
    expect(VaccinationRecordCheck.where(mode: "born_after_go_live").pluck(:patient_id)).to match_array(after.map(&:id))
    expect(VaccinationStatus.where(patient_id: before.id)).to exist
  end

  it "com a sala de vacina desligada, nada" do
    vaccine_patient!(birth_date: Time.zone.today - 70)
    Platform::Features.set!(city: city, key: "vaccination", enabled: false, maintainer: ledi_maintainer!)
    run!
    expect(VaccinationStatus.count).to eq(0)
  end

  it "está agendado todo dia às 3h" do
    task = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/recurring.yml")).fetch("production").fetch("vaccination_refresh_statuses")
    expect(task).to include("class" => "Vaccination::RefreshStatusesJob", "schedule" => "every day at 3am America/Sao_Paulo")
  end
end
