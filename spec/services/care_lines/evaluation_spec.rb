require "rails_helper"

RSpec.describe CareLines::Evaluation do
  before { care_city! }

  let(:unit) { care_unit! }
  let(:doctor) { care_doctor!(unit) }
  let(:team) { care_team!(unit, doctor) }

  it "avalia uma página de inscrições: diabético com consulta e PA hoje, HbA1c e pés vencidos" do
    patient = care_patient!(age: 58, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    enrollment = care_enrollment!(patient: patient, line: adopted_line!("diabetes_c4"), team: team, by: doctor)
    row = described_class.enrollments([ enrollment ], today: Time.zone.today).fetch(enrollment.id)
    statuses = row.practices.index_by(&:key)
    expect(statuses.transform_values(&:status)).to eq("c4_a" => "ok", "c4_b" => "ok", "c4_c" => "ok", "c4_d" => "untracked",
                                                      "c4_e" => "overdue", "c4_f" => "overdue")
    expect(row.worst).to eq("overdue")
  end

  it "gestante: âncora pela DUM cifrada da inscrição; criança: âncora pelo nascimento do paciente" do
    mom = care_patient!(age: 27, sex: "female", problems: [ %w[ciap2 W78] ], unit: unit, doctor: doctor)
    lmp = Time.zone.today - 70
    pregnant = care_enrollment!(patient: mom, line: adopted_line!("pregnancy_c3"), team: team, by: doctor, anchor_date: lmp)
    baby = care_patient!(age: 0, sex: "male")
    child = care_enrollment!(patient: baby, line: adopted_line!("child_c2"), team: team, by: doctor)
    rows = described_class.enrollments([ pregnant, child ], today: Time.zone.today)
    expect(rows[pregnant.id].practices.find { |p| p.key == "c3_a" }).to have_attributes(status: "ok", met: true)
    expect(rows[pregnant.id].practices.find { |p| p.key == "c3_h" }.due_on).to eq(lmp + 294)
    expect(rows[child.id].practices.find { |p| p.key == "c2_a" }.due_on).to eq(Date.iso8601(baby.birth_date) + 30)
    raw = ApplicationRecord.connection.select_value("SELECT anchor_date FROM care_line_enrollments WHERE id = '#{pregnant.id}'")
    expect(raw).not_to include(lmp.iso8601)
  end

  it "uma página de inscrições: o número de SQL não cresce com o número de inscrições" do
    line = adopted_line!("hypertension_c5")
    enrollments = Array.new(4) do
      patient = care_patient!(age: 55, sex: "female", problems: [ %w[ciap2 K86] ], unit: unit, doctor: doctor)
      care_enrollment!(patient: patient, line: line, team: team, by: doctor)
    end
    count = lambda do |list|
      queries = 0
      callback = ->(*, payload) { queries += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:sql].start_with?("SAVEPOINT", "RELEASE") }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        described_class.enrollments(CareLineEnrollment.where(id: list.map(&:id)).to_a, today: Time.zone.today)
      end
      queries
    end
    expect(count.call(enrollments.first(1))).to eq(count.call(enrollments))
  end
end
