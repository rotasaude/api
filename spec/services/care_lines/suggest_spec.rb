require "rails_helper"

# ADR 0040 (spec §2 decisões 2, 8, 9; plano, Desvios 5–7). Review Focus 1 e 2.
RSpec.describe CareLines::Suggest do
  include ActiveSupport::Testing::TimeHelpers

  before { care_city! }

  let(:today) { Time.zone.today }
  let(:unit) { care_unit! }
  let(:doctor) { care_doctor!(unit) }
  let!(:team) { care_team!(unit, doctor) }
  let!(:diabetes) { adopted_line!("diabetes_c4") }

  it "problema ativo → sugestão pendente da equipe da última consulta, com o problema como evidência; idempotente" do
    patient = care_patient!(age: 58, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    expect(described_class.run(today: today)).to eq(created: 1, closures: 0)
    suggestion = CareLineSuggestion.sole
    problem = patient.problems.sole
    expect(suggestion).to have_attributes(patient_id: patient.id, citizen_id: nil, care_line: diabetes, team: team, reason: "problem",
                                          status: "pending", evidence_ref: "patient_problem:#{problem.id}")
    expect(DomainEvent.where(name: "care_line_suggestion.created").last.payload).to eq("care_line_suggestion_id" => suggestion.id)
    expect(described_class.run(today: today)).to eq(created: 0, closures: 0)
  end

  it "idade e sexo e condição declarada olham pares validados sem paciente; par sem equipe não recebe" do
    elderly = adopted_line!("elderly_c6")
    neighborhood = care_neighborhood!(unit)
    older = care_citizen!(age: 72, sex: "female", neighborhood: neighborhood)
    homeless = care_citizen!(age: 75, sex: "male")
    declared = care_citizen!(age: 40, sex: "female", neighborhood: neighborhood)
    declare!(declared, "diabetes")
    described_class.run(today: today)
    expect(CareLineSuggestion.where(citizen_id: older.id).pluck(:care_line_id, :reason)).to eq([ [ elderly.id, "age_sex" ] ])
    expect(CareLineSuggestion.where(citizen_id: declared.id).pluck(:care_line_id, :reason)).to eq([ [ diabetes.id, "declared" ] ])
    expect(CareLineSuggestion.where(citizen_id: homeless.id)).not_to exist
  end

  it "recusada não volta por 365 dias; inscrito não recebe; linha inativa não sugere" do
    patient = care_patient!(age: 58, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    described_class.run(today: today)
    CareLineSuggestion.sole.update!(status: "dismissed", decided_by_user: doctor, decided_at: Time.current, dismiss_reason: "Acompanha no ambulatório")
    expect(described_class.run(today: today + 1)).to eq(created: 0, closures: 0)
    expect(described_class.run(today: today + 366)[:created]).to eq(0) # created_at real ainda é hoje: o corte usa created_at
    travel_to(366.days.from_now) { expect(described_class.run(today: Time.zone.today)[:created]).to eq(1) }
    CareLineSuggestion.where(status: "pending").delete_all
    care_enrollment!(patient: patient, line: diabetes, team: team, by: doctor)
    expect(described_class.run(today: today)[:created]).to eq(0)
    diabetes.update!(active: false)
    other = care_patient!(age: 60, sex: "female", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    described_class.run(today: today)
    expect(CareLineSuggestion.where(patient_id: other.id)).not_to exist
  end

  it "encerramento só com todos os problemas elegíveis resolvidos; nunca encerra sozinho" do
    patient = care_patient!(age: 58, sex: "male", problems: [ %w[ciap2 T90], %w[cid10 E119] ], unit: unit, doctor: doctor)
    enrollment = care_enrollment!(patient: patient, line: diabetes, team: team, by: doctor)
    resolve_problem!(patient, "T90", by: doctor)
    expect(described_class.run(today: today)).to eq(created: 0, closures: 0)
    resolve_problem!(patient, "E119", by: doctor)
    expect(described_class.run(today: today)).to eq(created: 0, closures: 1)
    closure = CareLineSuggestion.sole
    expect(closure).to have_attributes(reason: "resolved_problem", enrollment_id: enrollment.id, patient_id: patient.id, team: team)
    expect(enrollment.reload.status).to eq("active")
    expect(described_class.run(today: today)[:closures]).to eq(0)
  end

  it "for_patient e for_citizen: só a pessoa do evento" do
    patient = care_patient!(age: 58, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    care_patient!(age: 59, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    expect(described_class.for_patient(patient.id, today: today)).to eq(1)
    expect(CareLineSuggestion.pluck(:patient_id)).to eq([ patient.id ])
    citizen = care_citizen!(age: 30, sex: "female", neighborhood: care_neighborhood!(unit))
    declare!(citizen, "diabetes")
    expect(described_class.for_citizen(citizen.id, today: today)).to eq(1)
  end

  it "par com sugestão recusada que vira paciente não recebe outra por 365 dias" do
    patient = care_patient!(age: 58, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    pair = Citizen.find_by!(patient_id: patient.id)
    CareLineSuggestion.create!(citizen: pair, care_line: diabetes, team: team, reason: "declared", status: "dismissed",
                               decided_by_user: doctor, decided_at: Time.current, dismiss_reason: "Acompanha no ambulatório")
    expect(described_class.run(today: today)).to eq(created: 0, closures: 0)
    expect(CareLineSuggestion.where(patient_id: patient.id)).not_to exist
  end

  it "encerramento duplicado da mesma inscrição é recusado pelo índice e convive com a sugestão de inscrição pendente" do
    patient = care_patient!(age: 58, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    enrollment = care_enrollment!(patient: patient, line: diabetes, team: team, by: doctor)
    resolve_problem!(patient, "T90", by: doctor)
    described_class.run(today: today)
    attrs = { patient_id: patient.id, care_line_id: diabetes.id, team_id: team.id, reason: "resolved_problem", enrollment_id: enrollment.id }
    expect { CareLineSuggestion.create!(attrs) }.to raise_error(ActiveRecord::RecordNotUnique)
    CareLineSuggestion.create!(patient_id: patient.id, care_line_id: diabetes.id, team_id: team.id, reason: "problem")
    expect(CareLineSuggestion.where(patient_id: patient.id).pluck(:reason)).to contain_exactly("resolved_problem", "problem")
    expect(described_class.run(today: today)).to eq(created: 0, closures: 0)
  end
end
