require "rails_helper"

# Invariantes do ADR 0040.
RSpec.describe "Invariantes das linhas de cuidado (ADR 0040)" do
  def files(glob) = Dir[Rails.root.join(glob)].map { |f| Pathname(f).relative_path_from(Rails.root).to_s }

  it "nenhuma inscrição sem confirmação: só CareLines::Enroll cria inscrição" do
    writers = (files("app/**/*.rb") + files("lib/**/*.rb")).select { |f| File.read(Rails.root.join(f)).include?("CareLineEnrollment.create") }
    expect(writers).to eq([ "app/commands/care_lines/enroll.rb" ])
  end

  it "boa prática sem fonte no sistema nunca conta como atraso" do
    today = Date.new(2026, 10, 22)
    CareLines::Templates::Load.entries.each do |entry|
      untracked = entry["practices"].select { |p| CareLines::Catalog.untracked?(p["source"]) }
      practices = CareLines::Rules.practices(untracked.presence || entry["practices"].first(1)).payload[:practices]
      statuses = CareLines::Evaluate.call(practices: practices, person: CareLines::Person.new(birth_date: today - 20_000, sex: "female"),
                                          anchors: { "birth" => today - 400, "lmp" => today - 100, "enrollment" => today }, events: {}, today: today)
      statuses.select { |s| CareLines::Catalog.untracked?(s.source) }.each { |s| expect(s.status).to eq("untracked") }
    end
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
    end
    names = %w[care_line_suggestion.created care_line_suggestion.accepted care_line_enrollment.created care_outreach.recorded
               care_line_enrollment.ended citizen_condition.declared]
    events = DomainEvent.where(name: names).to_a
    expect(events.map(&:name).uniq).to match_array(names)
    events.each { |e| expect(e.payload.keys).to all(end_with("_id")), e.name }
    expect(log).not_to match(/Sangramento|Perda gestacional|#{(Time.zone.today - 63).iso8601}/)
  end
end
