require "rails_helper"

RSpec.describe "Consumidores das linhas de cuidado", type: :job do
  before { care_city! }

  let(:unit) { care_unit! }
  let(:doctor) { care_doctor!(unit) }
  let!(:team) { care_team!(unit, doctor) }
  let!(:line) { adopted_line!("diabetes_c4") }

  def args(name, payload) = { event_id: SecureRandom.uuid, event_name: name, city_slug: Current.city.slug, payload: payload }

  it "os eventos estão ligados aos consumidores" do
    expect(DomainEvents.registry["patient_problem.changed"].map(&:job)).to eq([ "CareLines::ProblemChangedJob" ])
    expect(DomainEvents.registry["citizen_condition.declared"].map(&:job)).to eq([ "CareLines::ConditionDeclaredJob" ])
  end

  it "problema mudou → sugestão daquele paciente; care_lines desligado → nada" do
    patient = care_patient!(age: 58, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    problem = patient.problems.sole
    Platform::Features.set!(city: Current.city, key: "care_lines", enabled: false, maintainer: ledi_maintainer!)
    CareLines::ProblemChangedJob.new.perform(**args("patient_problem.changed", "patient_problem_id" => problem.id, "kind" => "added"))
    expect(CareLineSuggestion.count).to eq(0)
    Platform::Features.set!(city: Current.city, key: "care_lines", enabled: true, maintainer: ledi_maintainer!)
    CareLines::ProblemChangedJob.new.perform(**args("patient_problem.changed", "patient_problem_id" => problem.id, "kind" => "added"))
    expect(CareLineSuggestion.sole.patient_id).to eq(patient.id)
  end

  it "condição declarada → sugestão daquele par" do
    citizen = care_citizen!(age: 30, sex: "female", neighborhood: care_neighborhood!(unit))
    declare!(citizen, "diabetes")
    CareLines::ConditionDeclaredJob.new.perform(**args("citizen_condition.declared", "citizen_id" => citizen.id))
    expect(CareLineSuggestion.sole).to have_attributes(citizen_id: citizen.id, reason: "declared")
  end
end
