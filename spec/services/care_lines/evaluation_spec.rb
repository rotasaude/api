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

  it "Row e PracticeStatus não revelam datas pessoais (DUM + janela) em inspect, to_s nem pretty_print" do
    mom = care_patient!(age: 27, sex: "female", problems: [ %w[ciap2 W78] ], unit: unit, doctor: doctor)
    lmp = Time.zone.today - 70
    enrollment = care_enrollment!(patient: mom, line: adopted_line!("pregnancy_c3"), team: team, by: doctor, anchor_date: lmp)
    row = described_class.enrollments([ enrollment ], today: Time.zone.today).fetch(enrollment.id)
    practice = row.practices.find { |p| p.key == "c3_h" }
    expect(practice.due_on).to eq(lmp + 294)
    dates = [ lmp, lmp + 294 ].map(&:iso8601)

    [ row, practice ].each do |value|
      [ value.inspect, value.to_s, value.pretty_inspect, "#{value}" ].each do |text|
        dates.each { |date| expect(text).not_to include(date) }
      end
    end
    expect(row.inspect).to eq("#<CareLines::Evaluation::Row key=#{enrollment.id.inspect} worst=#{row.worst}>")
    expect(practice.inspect).to eq("#<CareLines::PracticeStatus key=\"c3_h\" status=#{practice.status}>")
    expect(row.pretty_inspect.strip).to eq(row.inspect)
    expect(practice.pretty_inspect.strip).to eq(practice.inspect)
  end

  # Revisão final, Minor 7: o ActiveSupport faz Data#as_json = to_h.as_json;
  # sem a proteção, to_json/render json vazariam due_on e done_at (DUM + janela).
  it "Row e PracticeStatus não revelam datas pessoais em as_json nem to_json" do
    mom = care_patient!(age: 27, sex: "female", problems: [ %w[ciap2 W78] ], unit: unit, doctor: doctor)
    lmp = Time.zone.today - 70
    enrollment = care_enrollment!(patient: mom, line: adopted_line!("pregnancy_c3"), team: team, by: doctor, anchor_date: lmp)
    row = described_class.enrollments([ enrollment ], today: Time.zone.today).fetch(enrollment.id)
    practice = row.practices.find { |p| p.key == "c3_h" }
    done = practice.with(done_at: lmp + 10)

    expect(done.as_json).to eq("key" => "c3_h", "status" => done.status)
    expect(row.as_json).to eq("key" => enrollment.id, "worst" => row.worst)
    [ row.to_json, done.to_json, { rows: [ row ] }.to_json ].each do |text|
      [ lmp, lmp + 10, lmp + 294 ].map(&:iso8601).each { |date| expect(text).not_to include(date) }
    end
  end
end
