require "rails_helper"

# Plano, Desvio 5: equipe da pessoa para sugestão e prévia.
RSpec.describe CareLines::TeamPopulation do
  include ActiveSupport::Testing::TimeHelpers

  before { care_city! }

  let(:unit_a) { care_unit! }
  let(:doctor_a) { care_doctor!(unit_a) }
  let!(:team_a) { care_team!(unit_a, doctor_a) }
  let(:unit_b) { care_unit! }
  let(:doctor_b) { care_doctor!(unit_b) }
  let!(:team_b) { care_team!(unit_b, doctor_b) }
  let(:diabetes) { adopted_line!("diabetes_c4") }

  def count_queries(&block)
    count = 0
    counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    count
  end

  it "paciente vai para a equipe do profissional da última consulta; inscrito, para a equipe da inscrição" do
    p1 = care_patient!(age: 60, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit_a, doctor: doctor_a)
    p2 = care_patient!(age: 61, sex: "female", problems: [ %w[ciap2 T90] ], unit: unit_a, doctor: doctor_a)
    care_enrollment!(patient: p2, line: diabetes, team: team_b, by: doctor_b)
    expect(described_class.patient_teams([ p1.id, p2.id ])).to eq(p1.id => team_a.id, p2.id => team_a.id)
    population_a = described_class.call(team: team_a, line: diabetes, rules: diabetes.eligibility)
    population_b = described_class.call(team: team_b, line: diabetes, rules: diabetes.eligibility)
    expect(population_a.map { |person, _| person.patient_id }).to eq([ p1.id ])
    expect(population_b.map { |person, enrollment| [ person.patient_id, enrollment.present? ] }).to eq([ [ p2.id, true ] ])
  end

  it "par validado sem paciente: a única equipe das unidades de referência do bairro; com duas, ninguém" do
    single = care_neighborhood!(unit_a)
    shared = care_neighborhood!(unit_a, unit_b)
    alone = care_citizen!(age: 72, sex: "female", neighborhood: single)
    split = care_citizen!(age: 73, sex: "female", neighborhood: shared)
    expect(described_class.citizen_teams([ alone, split ])).to eq(alone.id => team_a.id)
    elderly = adopted_line!("elderly_c6")
    people = described_class.call(team: team_a, line: elderly, rules: elderly.eligibility).map(&:first)
    expect(people.map(&:citizen_id)).to include(alone.id)
    expect(people.map(&:citizen_id)).not_to include(split.id)
  end

  it "consulta de mais de 24 meses não atribui" do
    old = travel_to(25.months.ago) { care_patient!(age: 70, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit_a, doctor: doctor_a) }
    expect(described_class.patient_teams([ old.id ])).to eq({})
  end

  it "desempata pelo INE quando o profissional está em duas equipes da unidade: trocar os INEs troca o vencedor" do
    other = HealthTeam.create!(health_unit: unit_a, ine: "0000000001", kind: "70", name: "ESF B")
    team_a.update!(ine: "0000000002")
    HealthTeamMember.create!(professional: doctor_a.professional, health_team: other, cbo_code: "225125", started_on: Time.zone.today - 30)
    patient = care_patient!(age: 60, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit_a, doctor: doctor_a)
    expect(described_class.patient_teams([ patient.id ])).to eq(patient.id => other.id)
    other.update!(ine: "0000000003")
    expect(described_class.patient_teams([ patient.id ])).to eq(patient.id => team_a.id)
  end

  def second_consultation!(patient, unit:, doctor:)
    problem = PatientProblem.find_by!(patient_id: patient.id)
    finalized_consultation!(unit: unit, doctor: doctor, citizen: Citizen.find_by!(patient_id: patient.id),
                            evaluated_problems: [ { "problem_id" => problem.id, "action" => "evaluate" } ], exam_requests: [])
  end

  it "duas consultas finalizadas: vale a equipe da MAIS RECENTE" do
    patient = travel_to(3.months.ago) { care_patient!(age: 60, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit_a, doctor: doctor_a) }
    expect(described_class.patient_teams([ patient.id ])).to eq(patient.id => team_a.id)
    travel_to(1.month.ago) { second_consultation!(patient, unit: unit_b, doctor: doctor_b) }
    expect(described_class.patient_teams([ patient.id ])).to eq(patient.id => team_b.id)
  end

  it "profissional de equipe da unidade B que consulta pelo vínculo da unidade A não dá equipe" do
    link_professional!(doctor_b, unit_a)
    patient = care_patient!(age: 60, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit_a, doctor: doctor_b)
    expect(Consultation.find_by!(patient_id: patient.id).professional_link.health_unit_id).to eq(unit_a.id)
    expect(described_class.patient_teams([ patient.id ])).to eq({})
  end

  it "consulta mais recente com profissional sem equipe não tira a pessoa da equipe anterior" do
    patient = travel_to(3.months.ago) { care_patient!(age: 60, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit_a, doctor: doctor_a) }
    on_duty = care_doctor!(unit_a)
    travel_to(1.month.ago) { second_consultation!(patient, unit: unit_a, doctor: on_duty) }
    expect(described_class.patient_teams([ patient.id ])).to eq(patient.id => team_a.id)
  end

  it "equipe inativa e membro desligado não atribuem" do
    patient = care_patient!(age: 60, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit_a, doctor: doctor_a)
    HealthTeamMember.where(health_team: team_a).update_all(ended_on: Time.zone.today)
    expect(described_class.patient_teams([ patient.id ])).to eq({})
    HealthTeamMember.where(health_team: team_a).update_all(ended_on: nil)
    team_a.update!(active: false)
    expect(described_class.patient_teams([ patient.id ])).to eq({})
  end

  it "pré-filtro por equipe: só quem teve consulta de membro da equipe na unidade dela; a equipe atribuída não muda" do
    mine = care_patient!(age: 60, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit_a, doctor: doctor_a)
    theirs = care_patient!(age: 61, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit_b, doctor: doctor_b)
    moved = travel_to(3.months.ago) { care_patient!(age: 62, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit_a, doctor: doctor_a) }
    travel_to(1.month.ago) { second_consultation!(moved, unit: unit_b, doctor: doctor_b) }
    expect(described_class.patient_teams(nil, involving_team: team_a)).to eq(mine.id => team_a.id, moved.id => team_b.id)
    expect(described_class.patient_teams(nil, involving_team: team_b)).to eq(theirs.id => team_b.id, moved.id => team_b.id)
    expect(described_class.patient_teams([ mine.id ], involving_team: team_b)).to eq({})
    population = described_class.call(team: team_a, line: diabetes, rules: diabetes.eligibility).map { |person, _| person.patient_id }
    expect(population).to eq([ mine.id ])
  end

  it "inscrita em pregnancy_c3 é avaliada com a DUM: problema excludente anterior à DUM não a tira do denominador" do
    pregnancy = adopted_line!("pregnancy_c3")
    attrs = { age: 28, sex: "female", problems: [ %w[ciap2 W78], %w[ciap2 W82] ], unit: unit_a, doctor: doctor_a }
    enrolled = travel_to(100.days.ago) { care_patient!(**attrs) }
    travel_to(100.days.ago) { care_patient!(**attrs) }
    care_enrollment!(patient: enrolled, line: pregnancy, team: team_a, by: doctor_a, anchor_date: Time.zone.today - 60)
    people = described_class.call(team: team_a, line: pregnancy, rules: pregnancy.eligibility).map { |person, enrollment| [ person.patient_id, enrollment.present? ] }
    expect(people).to eq([ [ enrolled.id, true ] ])
  end

  it "o número de consultas ao banco não cresce com o número de pessoas" do
    neighborhood = care_neighborhood!(unit_a)
    elderly = adopted_line!("elderly_c6")
    care_citizen!(age: 70, sex: "female", neighborhood: neighborhood)
    care_patient!(age: 65, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit_a, doctor: doctor_a)
    small = count_queries { described_class.call(team: team_a, line: elderly, rules: elderly.eligibility) }
    4.times do
      care_citizen!(age: 70, sex: "female", neighborhood: neighborhood)
      care_patient!(age: 66, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit_a, doctor: doctor_a)
    end
    big = nil
    expect { big = count_queries { described_class.call(team: team_a, line: elderly, rules: elderly.eligibility) } }.not_to raise_error
    expect(described_class.call(team: team_a, line: elderly, rules: elderly.eligibility).size).to eq(10)
    expect(big).to eq(small)
  end
end
