require "rails_helper"

# Invariantes do ADR 0040.
RSpec.describe "Invariantes das linhas de cuidado (ADR 0040)" do
  def files(glob) = Dir[Rails.root.join(glob)].map { |f| Pathname(f).relative_path_from(Rails.root).to_s }

  # Qualquer forma de gravar inscrição: create/new/insert/upsert no modelo,
  # pela associação (enrollments.create/new/build/...) ou SQL cru.
  def enrollment_write = /CareLineEnrollment\s*\.\s*(create|new|insert|upsert)|enrollments\s*\.\s*(create|new|build|insert|upsert)|INSERT\s+INTO\s+"?care_line_enrollments/i

  it "nenhuma inscrição sem confirmação: só CareLines::Enroll cria inscrição" do
    writers = (files("app/**/*.rb") + files("lib/**/*.rb")).select { |f| File.read(Rails.root.join(f)).match?(enrollment_write) }
    expect(writers).to eq([ "app/commands/care_lines/enroll.rb" ])
    %w[CareLineEnrollment.new(attrs).save patient.care_line_enrollments.build(x) CareLineEnrollment.insert_all(rows)
       CareLineEnrollment.upsert(row) enrollments.create!(x)].each { |code| expect(code).to match(enrollment_write) }
    expect('execute("INSERT INTO care_line_enrollments (id) VALUES (1)")').to match(enrollment_write)
  end

  # Cada linha do catálogo-base, com uma pessoa a quem a prática não
  # rastreada se aplica (na C7, uma menina de 9 a 14 anos para a HPV): a
  # prática é avaliada (conta > 0) e é untracked; o pior da linha e o
  # contador de vencidos não a contam.
  it "boa prática sem fonte no sistema nunca conta como atraso" do
    today = Date.new(2026, 10, 22)
    CareLines::Templates::Load.entries.each do |entry|
      untracked = entry["practices"].select { |p| CareLines::Catalog.untracked?(p["source"]) }
      expect(untracked).not_to be_empty, entry["key"]
      practices = CareLines::Rules.practices(entry["practices"]).payload[:practices]
      untracked.each do |practice|
        rule = practice["applies_to"] || {}
        age = rule["age_min_years"] ? (rule["age_min_years"] + rule.fetch("age_max_years", rule["age_min_years"])) / 2 : 54
        birth = today.prev_year(age) - 30
        person = CareLines::Person.new(birth_date: birth, sex: rule["sex"] || "female")
        statuses = CareLines::Evaluate.call(practices: practices, person: person, events: {}, today: today,
                                            anchors: { "birth" => birth, "lmp" => today - 100, "enrollment" => today - 400 })
        evaluated = statuses.reject(&:tracked)
        expect(evaluated.map(&:key)).to include(practice["key"]), "#{entry["key"]}/#{practice["key"]}"
        expect(evaluated.map(&:status).uniq).to eq([ "untracked" ])
        expect(CareLines::Evaluate.worst(statuses)).to eq(CareLines::Evaluate.worst(statuses.select(&:tracked)))
        expect(CareLines::Evaluate.worst(evaluated)).to eq("untracked")
      end
    end
  end

  it "o contador de vencidos e o pior da inscrição não contam a prática não rastreada" do
    care_city!
    unit = care_unit!
    doctor = care_doctor!(unit)
    team = care_team!(unit, doctor)
    today = Time.zone.today
    base = adopted_line!("elderly_c6")
    only_untracked = CareLine.create!(source: "custom", name: "Só fora do sistema", eligibility: base.eligibility,
                                      practices: base.practices.select { |p| CareLines::Catalog.untracked?(p["source"]) },
                                      updated_by_user: care_admin!)
    patient = care_patient!(age: 72, sex: "female")
    enrollment = care_enrollment!(patient: patient, line: only_untracked, team: team, by: doctor, enrolled_at: 400.days.ago)
    row = CareLines::Evaluation.enrollments([ enrollment ], today: today).fetch(enrollment.id)
    expect(row.practices.map(&:status)).to eq(%w[untracked untracked])
    expect(row.worst).to eq("untracked")
    expect(CareLines::Board.overdue_count(team, today: today)).to eq(0)
    # Controle: a mesma pessoa numa linha com práticas rastreadas, sem nenhum evento, conta.
    tracked = care_enrollment!(patient: patient, line: base, team: team, by: doctor, enrolled_at: 400.days.ago)
    expect(CareLines::Evaluation.enrollments([ tracked ], today: today).fetch(tracked.id).worst).to eq("overdue")
    expect(CareLines::Board.overdue_count(team, today: today)).to eq(1)
  end

  it "o cidadão nunca recebe sugestão nem motivo: as rotas /citizen não leem sugestões" do
    citizen_code = files("app/controllers/citizen_api/**/*.rb").map { |f| File.read(Rails.root.join(f)) }.join
    citizen_code += File.read(Rails.root.join("app/services/care_lines/citizen_view.rb"))
    expect(citizen_code).not_to match(/CareLineSuggestion|ended_reason|ended_note|dismiss_reason/)
  end

  it "eventos das linhas só com ids; nota, condição e DUM nunca no log" do
    care_city!
    unit = care_unit!
    doctor = care_doctor!(unit)
    team = care_team!(unit, doctor)
    adopted_line!("pregnancy_c3")
    citizen = care_citizen!(age: 27, sex: "female", neighborhood: care_neighborhood!(unit))
    log = capture_log do
      CareLines::DeclareCondition.call(citizen: citizen, condition: "pregnancy")
      CareLines::Suggest.for_citizen(citizen.id)
      suggestion = CareLineSuggestion.sole
      enrollment = CareLines::AcceptSuggestion.call(suggestion: suggestion, team: team, by: doctor,
                                                    anchor_date: (Time.zone.today - 63).iso8601).payload[:enrollment]
      CareLines::RecordContact.call(enrollment: enrollment, channel: "phone", outcome: "reached", note: "Sangramento leve relatado", by: doctor)
      CareLines::EndEnrollment.call(enrollment: enrollment, reason: "pregnancy_ended", note: "Perda gestacional na 9ª semana", by: doctor)
      other = CareLineSuggestion.create!(care_line: adopted_line!("women_c7"), team: team, patient: enrollment.patient, reason: "age_sex")
      CareLines::DismissSuggestion.call(suggestion: other, reason: "Acompanha no consultório particular", by: doctor)
    end
    names = %w[care_line_suggestion.created care_line_suggestion.accepted care_line_suggestion.dismissed care_line_enrollment.created
               care_outreach.recorded care_line_enrollment.ended citizen_condition.declared]
    events = DomainEvent.where(name: names).to_a
    expect(events.map(&:name).uniq).to match_array(names)
    events.each { |e| expect(e.payload.keys).to all(end_with("_id")), e.name }
    expect(log).to include("care_line_suggestions") # o log foi capturado
    expect(log).not_to match(/Sangramento|Perda gestacional|consultório particular|#{(Time.zone.today - 63).iso8601}/)
    # A condição declarada ("pregnancy" sozinha; pregnancy_c3/pregnancy_ended são códigos de linha e de saída).
    expect(log).not_to match(/\bpregnancy\b/)
  end
end
