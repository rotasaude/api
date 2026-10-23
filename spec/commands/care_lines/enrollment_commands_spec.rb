require "rails_helper"

# ADR 0040 (Invariantes: nenhuma inscrição sem confirmação de um
# profissional); spec §2 decisões 2 e 8; plano, Desvios 4 e 8. Review Focus 4.
RSpec.describe "Inscrição confirmada e saída" do
  before { care_city! }

  let(:today) { Time.zone.today }
  let(:unit) { care_unit! }
  let(:doctor) { care_doctor!(unit) }
  let(:nurse) { care_nurse!(unit) }
  let(:tech) { screener!(unit, cbo: "322205") }
  let!(:team) { care_team!(unit, doctor, nurse) }

  def pending_for(line, citizen: nil, patient: nil)
    CareLineSuggestion.create!(care_line: line, team: team, reason: citizen ? "age_sex" : "problem", citizen: citizen, patient: patient)
  end

  it "aceitar sugestão de par validado sem paciente cria o paciente (Patients::Resolve) e a inscrição; só ids nos eventos" do
    line = adopted_line!("elderly_c6")
    citizen = care_citizen!(age: 72, sex: "female")
    suggestion = pending_for(line, citizen: citizen)
    result = CareLines::AcceptSuggestion.call(suggestion: suggestion, team: team, by: nurse, today: today)
    enrollment = result.payload[:enrollment]
    expect(enrollment).to have_attributes(patient_id: citizen.reload.patient_id, source: "suggestion", suggestion_id: suggestion.id, status: "active")
    expect(suggestion.reload).to have_attributes(status: "accepted", decided_by_user_id: nurse.id)
    expect(DomainEvent.where(name: "care_line_enrollment.created").last.payload.keys).to match_array(%w[care_line_enrollment_id user_id])
    expect(DomainEvent.where(name: "care_line_suggestion.accepted").last.payload.keys).to match_array(%w[care_line_suggestion_id user_id])
    again = CareLines::AcceptSuggestion.call(suggestion: suggestion, team: team, by: nurse, today: today)
    expect(again.reason).to eq(:invalid_transition)
  end

  it "só médico ou enfermeiro confirma; linha inativa recusa; par que perdeu a validação recusa" do
    line = adopted_line!("elderly_c6")
    citizen = care_citizen!(age: 72, sex: "female")
    suggestion = pending_for(line, citizen: citizen)
    expect(CareLines::AcceptSuggestion.call(suggestion: suggestion, team: team, by: tech, today: today).reason).to eq(:cbo_not_allowed)
    citizen.update_columns(verification_level: "declared")
    expect(CareLines::AcceptSuggestion.call(suggestion: suggestion, team: team, by: doctor, today: today).reason).to eq(:citizen_not_verified)
    expect(suggestion.reload).to be_pending
    line.update!(active: false)
    patient = care_patient!(age: 70, sex: "male")
    expect(CareLines::Enroll.call(patient: patient, line: line, team: team, by: doctor).reason).to eq(:line_inactive)
  end

  it "gestante: DUM obrigatória e entre hoje − 336 e hoje; gravada cifrada; nada gravado na recusa" do
    line = adopted_line!("pregnancy_c3")
    patient = care_patient!(age: 27, sex: "female", problems: [ %w[ciap2 W78] ], unit: unit, doctor: doctor)
    suggestion = pending_for(line, patient: patient)
    expect(CareLines::AcceptSuggestion.call(suggestion: suggestion, team: team, by: doctor, today: today).reason).to eq(:anchor_required)
    [ (today + 1).iso8601, (today - 337).iso8601, "2026-13-01", "ontem" ].each do |bad|
      result = CareLines::AcceptSuggestion.call(suggestion: suggestion, team: team, by: doctor, anchor_date: bad, today: today)
      expect(result.reason).to eq(:invalid_anchor), bad
    end
    expect(CareLineEnrollment.count).to eq(0)
    expect(suggestion.reload).to be_pending
    ok = CareLines::AcceptSuggestion.call(suggestion: suggestion, team: team, by: doctor, anchor_date: (today - 70).iso8601, today: today)
    expect(ok.payload[:enrollment].anchor_on).to eq(today - 70)
    expect(CareLines::Enroll.call(patient: patient, line: adopted_line!("diabetes_c4"), team: team, by: doctor, anchor_date: today.iso8601).reason)
      .to eq(:invalid_anchor)
  end

  it "inscrição manual repetida → already_enrolled" do
    line = adopted_line!("diabetes_c4")
    patient = care_patient!(age: 58, sex: "male")
    expect(CareLines::Enroll.call(patient: patient, line: line, team: team, by: doctor)).to be_ok
    expect(CareLines::Enroll.call(patient: patient, line: line, team: team, by: nurse).reason).to eq(:already_enrolled)
  end

  it "recusar exige motivo (até 500); sugestão de encerramento aceita encerra com discharge" do
    line = adopted_line!("diabetes_c4")
    patient = care_patient!(age: 58, sex: "male")
    suggestion = pending_for(line, patient: patient)
    expect(CareLines::DismissSuggestion.call(suggestion: suggestion, reason: "  ", by: doctor).details).to eq(field: "reason")
    expect(CareLines::DismissSuggestion.call(suggestion: suggestion, reason: "x" * 501, by: doctor).reason).to eq(:too_long)
    expect(CareLines::DismissSuggestion.call(suggestion: suggestion, reason: "Segue no ambulatório de endocrinologia", by: doctor)).to be_ok
    enrollment = CareLines::Enroll.call(patient: patient, line: line, team: team, by: doctor).payload[:enrollment]
    closure = CareLineSuggestion.create!(care_line: line, team: team, patient: patient, reason: "resolved_problem", enrollment: enrollment)
    result = CareLines::AcceptSuggestion.call(suggestion: closure, by: tech, today: today)
    expect(result.payload[:ended]).to have_attributes(status: "ended", ended_reason: "discharge", ended_by_user_id: tech.id)
  end

  it "encerrar com motivo do domínio e nota opcional; encerrar de novo recusa; a sugestão de encerramento pendente fica aceita" do
    line = adopted_line!("diabetes_c4")
    enrollment = CareLines::Enroll.call(patient: care_patient!(age: 58, sex: "male"), line: line, team: team, by: doctor).payload[:enrollment]
    closure = CareLineSuggestion.create!(care_line: line, team: team, patient: enrollment.patient, reason: "resolved_problem", enrollment: enrollment)
    expect(CareLines::EndEnrollment.call(enrollment: enrollment, reason: "cured", note: nil, by: doctor).reason).to eq(:invalid_reason)
    expect(CareLines::EndEnrollment.call(enrollment: enrollment, reason: "moved", note: "n" * 501, by: doctor).details).to eq(field: "note")
    expect(CareLines::EndEnrollment.call(enrollment: enrollment, reason: "moved", note: "Mudou para Maringá", by: doctor)).to be_ok
    expect(enrollment.reload).to have_attributes(status: "ended", ended_reason: "moved", ended_note: "Mudou para Maringá")
    expect(closure.reload.status).to eq("accepted")
    expect(CareLines::EndEnrollment.call(enrollment: enrollment, reason: "moved", note: nil, by: doctor).reason).to eq(:invalid_transition)
  end

  it "contato: canal e desfecho do domínio, nota cifrada até 500, só em inscrição ativa" do
    enrollment = CareLines::Enroll.call(patient: care_patient!(age: 58, sex: "male"), line: adopted_line!("diabetes_c4"), team: team,
                                        by: doctor).payload[:enrollment]
    expect(CareLines::RecordContact.call(enrollment: enrollment, channel: "sms", outcome: "reached", note: nil, by: tech).reason).to eq(:invalid_channel)
    expect(CareLines::RecordContact.call(enrollment: enrollment, channel: "phone", outcome: "maybe", note: nil, by: tech).reason).to eq(:invalid_outcome)
    contact = CareLines::RecordContact.call(enrollment: enrollment, channel: "phone", outcome: "scheduled", note: "Marcou para terça", by: tech)
    expect(contact.payload[:contact]).to have_attributes(recorded_by_user_id: tech.id, note: "Marcou para terça")
    expect(DomainEvent.where(name: "care_outreach.recorded").last.payload.keys)
      .to match_array(%w[care_outreach_contact_id care_line_enrollment_id user_id])
    CareLines::EndEnrollment.call(enrollment: enrollment, reason: "death", note: nil, by: doctor)
    expect(CareLines::RecordContact.call(enrollment: enrollment.reload, channel: "phone", outcome: "reached", note: nil, by: tech).reason)
      .to eq(:invalid_transition)
  end

  # Errata, Task 11 (Task 5 I4): a inscrição à mão fecha a sugestão pendente da mesma pessoa e linha.
  it "inscrever à mão com sugestão pendente (do paciente e do par) deixa todas aceitas, a primeira ligada à inscrição" do
    line = adopted_line!("diabetes_c4")
    patient = care_patient!(age: 58, sex: "male")
    by_patient = pending_for(line, patient: patient)
    by_citizen = pending_for(line, citizen: patient.citizens.first)
    other_line = pending_for(adopted_line!("hypertension_c5"), patient: patient)
    result = CareLines::Enroll.call(patient: patient, line: line, team: team, by: nurse)
    enrollment = result.payload[:enrollment]
    first = [ by_patient, by_citizen ].min_by(&:id)
    expect(enrollment).to have_attributes(source: "suggestion", suggestion_id: first.id)
    expect([ by_patient, by_citizen ].map { |s| s.reload.status }).to eq(%w[accepted accepted])
    expect(by_patient.reload).to have_attributes(decided_by_user_id: nurse.id)
    expect(by_patient.decided_at).to be_present
    expect(other_line.reload).to be_pending
    expect(CareLineSuggestion.pending_suggestions.where(care_line: line)).to be_empty
    expect(DomainEvent.where(name: "care_line_suggestion.accepted").count).to eq(2)
  end

  it "a sugestão de encerramento pendente não é aceita pela inscrição à mão" do
    line = adopted_line!("diabetes_c4")
    patient = care_patient!(age: 58, sex: "male")
    first = CareLines::Enroll.call(patient: patient, line: line, team: team, by: doctor).payload[:enrollment]
    closure = CareLineSuggestion.create!(care_line: line, team: team, patient: patient, reason: "resolved_problem", enrollment: first)
    first.update!(status: "ended", ended_reason: "moved", ended_at: Time.current, ended_by_user: doctor)
    again = CareLines::Enroll.call(patient: patient, line: line, team: team, by: doctor).payload[:enrollment]
    expect(again).to have_attributes(source: "manual", suggestion_id: nil)
    expect(closure.reload).to be_pending
    expect(CareLines::Enroll.call(patient: patient, line: line, team: team, by: doctor).reason).to eq(:already_enrolled)
  end

  # Errata P-api-01 / L3: 223115 (família 2231) confirma; o catálogo ganha a entrada só neste exemplo.
  it "médico de CBO 223115 confirma; técnica de enfermagem não" do
    family_cbo = Professionals::Cbo::Entry.new(code: "223115", title: "Médico (família 2231)", council: "CRM", deprecated: false)
    allow(Professionals::Cbo).to(receive(:all).and_wrap_original { |original| original.call + [ family_cbo ] })
    family = screener!(unit, cbo: "223115")
    line = adopted_line!("diabetes_c4")
    expect(CareLines::Enroll.call(patient: care_patient!(age: 58, sex: "male"), line: line, team: team, by: family)).to be_ok
    expect(CareLines::Enroll.call(patient: care_patient!(age: 59, sex: "male"), line: line, team: team, by: tech).reason).to eq(:cbo_not_allowed)
    other_unit = screener!(care_unit!, cbo: "225125")
    expect(CareLines::Enroll.call(patient: care_patient!(age: 60, sex: "male"), line: line, team: team, by: other_unit).reason).to eq(:cbo_not_allowed)
  end

  it "a DUM fica cifrada no banco e o evento traz só ids" do
    line = adopted_line!("pregnancy_c3")
    patient = care_patient!(age: 27, sex: "female")
    dum = (today - 70).iso8601
    enrollment = CareLines::Enroll.call(patient: patient, line: line, team: team, by: doctor, anchor_date: dum).payload[:enrollment]
    raw = CareLineEnrollment.connection.select_value("SELECT anchor_date FROM care_line_enrollments WHERE id = '#{enrollment.id}'")
    expect(raw).to be_present
    expect(raw).not_to include(dum)
    expect(enrollment.reload.anchor_on).to eq(today - 70)
    expect(enrollment.inspect).not_to include(dum)
    expect(DomainEvent.where(name: "care_line_enrollment.created").last.payload.to_json).not_to include(dum)
  end

  it "recusar grava o motivo cifrado, só ids no evento, e recusa de novo" do
    line = adopted_line!("diabetes_c4")
    suggestion = pending_for(line, patient: care_patient!(age: 58, sex: "male"))
    CareLines::DismissSuggestion.call(suggestion: suggestion, reason: "Segue no ambulatório", by: nurse)
    raw = CareLineSuggestion.connection.select_value("SELECT dismiss_reason FROM care_line_suggestions WHERE id = '#{suggestion.id}'")
    expect(raw).not_to include("ambulatório")
    expect(suggestion.reload).to have_attributes(status: "dismissed", decided_by_user_id: nurse.id, dismiss_reason: "Segue no ambulatório")
    expect(DomainEvent.where(name: "care_line_suggestion.dismissed").last.payload.keys).to match_array(%w[care_line_suggestion_id user_id])
    expect(CareLines::DismissSuggestion.call(suggestion: suggestion, reason: "outra", by: nurse).reason).to eq(:invalid_transition)
  end

  it "encerrar grava a nota cifrada e só ids no evento" do
    enrollment = CareLines::Enroll.call(patient: care_patient!(age: 58, sex: "male"), line: adopted_line!("diabetes_c4"), team: team,
                                        by: doctor).payload[:enrollment]
    CareLines::EndEnrollment.call(enrollment: enrollment, reason: "moved", note: "Mudou para Maringá", by: doctor)
    raw = CareLineEnrollment.connection.select_value("SELECT ended_note FROM care_line_enrollments WHERE id = '#{enrollment.id}'")
    expect(raw).not_to include("Maringá")
    expect(DomainEvent.where(name: "care_line_enrollment.ended").last.payload.keys).to match_array(%w[care_line_enrollment_id user_id])
  end

  it "aceitar a sugestão de encerramento de inscrição já encerrada só decide a sugestão" do
    line = adopted_line!("diabetes_c4")
    enrollment = CareLines::Enroll.call(patient: care_patient!(age: 58, sex: "male"), line: line, team: team, by: doctor).payload[:enrollment]
    closure = CareLineSuggestion.create!(care_line: line, team: team, patient: enrollment.patient, reason: "resolved_problem", enrollment: enrollment)
    enrollment.update!(status: "ended", ended_reason: "moved", ended_at: Time.current, ended_by_user: doctor)
    result = CareLines::AcceptSuggestion.call(suggestion: closure, by: nurse, today: today)
    expect(result.payload[:ended]).to have_attributes(ended_reason: "moved")
    expect(closure.reload).to have_attributes(status: "accepted", decided_by_user_id: nurse.id)
  end

  # Ordem de travas (Desvio 8; errata C-api-02, C-api-04): sugestão antes da inscrição.
  def for_update_tables
    tables = []
    callback = lambda do |*, payload|
      sql = payload[:sql]
      next unless sql.include?("FOR UPDATE")

      tables << sql[/FROM "(care_line_suggestions|care_line_enrollments|patients)"/, 1]
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    tables.compact
  end

  it "EndEnrollment trava as sugestões de encerramento antes da inscrição" do
    line = adopted_line!("diabetes_c4")
    enrollment = CareLines::Enroll.call(patient: care_patient!(age: 58, sex: "male"), line: line, team: team, by: doctor).payload[:enrollment]
    CareLineSuggestion.create!(care_line: line, team: team, patient: enrollment.patient, reason: "resolved_problem", enrollment: enrollment)
    tables = for_update_tables { CareLines::EndEnrollment.call(enrollment: enrollment, reason: "moved", note: nil, by: doctor) }
    expect(tables.index("care_line_suggestions")).to be < tables.index("care_line_enrollments")
  end

  it "RecordContact trava a inscrição antes de conferir que está ativa" do
    enrollment = CareLines::Enroll.call(patient: care_patient!(age: 58, sex: "male"), line: adopted_line!("diabetes_c4"), team: team,
                                        by: doctor).payload[:enrollment]
    tables = for_update_tables { CareLines::RecordContact.call(enrollment: enrollment, channel: "phone", outcome: "reached", note: nil, by: tech) }
    expect(tables).to include("care_line_enrollments")
  end

  it "Enroll à mão trava as sugestões antes do paciente" do
    line = adopted_line!("diabetes_c4")
    patient = care_patient!(age: 58, sex: "male")
    pending_for(line, patient: patient)
    tables = for_update_tables { CareLines::Enroll.call(patient: patient, line: line, team: team, by: doctor) }
    expect(tables.index("care_line_suggestions")).to be < tables.index("patients")
  end

  it "aceitar a sugestão de encerramento trava a sugestão antes da inscrição" do
    line = adopted_line!("diabetes_c4")
    enrollment = CareLines::Enroll.call(patient: care_patient!(age: 58, sex: "male"), line: line, team: team, by: doctor).payload[:enrollment]
    closure = CareLineSuggestion.create!(care_line: line, team: team, patient: enrollment.patient, reason: "resolved_problem", enrollment: enrollment)
    tables = for_update_tables { CareLines::AcceptSuggestion.call(suggestion: closure, by: nurse, today: today) }
    expect(tables.index("care_line_suggestions")).to be < tables.index("care_line_enrollments")
  end

  # Review Focus 4: recusa pura não grava nada, nem o paciente que o Resolve criaria.
  it "sugestão declared de par sem paciente: DUM ausente ou inválida não cria paciente, vínculo nem evento" do
    line = adopted_line!("pregnancy_c3")
    citizen = care_citizen!(age: 27, sex: "female")
    suggestion = CareLineSuggestion.create!(care_line: line, team: team, reason: "declared", citizen: citizen)
    [ [ nil, :anchor_required ], [ (today + 1).iso8601, :invalid_anchor ], [ "ontem", :invalid_anchor ] ].each do |dum, reason|
      patients = Patient.count
      created = DomainEvent.where(name: %w[patient.created patient.linked]).count
      result = CareLines::AcceptSuggestion.call(suggestion: suggestion, team: team, by: doctor, anchor_date: dum, today: today)
      expect(result.reason).to eq(reason)
      expect(Patient.count).to eq(patients)
      expect(citizen.reload.patient_id).to be_nil
      expect(DomainEvent.where(name: %w[patient.created patient.linked]).count).to eq(created)
      expect(suggestion.reload).to be_pending
    end
    line.update!(active: false)
    patients = Patient.count
    expect(CareLines::AcceptSuggestion.call(suggestion: suggestion, team: team, by: doctor, anchor_date: today.iso8601, today: today).reason)
      .to eq(:line_inactive)
    expect(Patient.count).to eq(patients)
  end

  it "sugestão já decidida ou inscrito já ativo recusa antes de criar o paciente" do
    line = adopted_line!("elderly_c6")
    citizen = care_citizen!(age: 72, sex: "female")
    suggestion = pending_for(line, citizen: citizen)
    suggestion.update_columns(status: "dismissed", decided_at: Time.current, decided_by_user_id: doctor.id, dismiss_reason: "x")
    patients = Patient.count
    expect(CareLines::AcceptSuggestion.call(suggestion: suggestion, team: team, by: doctor, today: today).reason).to eq(:invalid_transition)
    expect(Patient.count).to eq(patients)
  end

  # Dois pares validados do mesmo CPF, cada um com a sua sugestão: aceitar uma decide as duas.
  it "aceitar uma sugestão aceita todas as pendentes da pessoa e linha, inclusive a de outro par do mesmo CPF" do
    line = adopted_line!("elderly_c6")
    first = care_citizen!(age: 72, sex: "female")
    second = care_citizen!(age: 72, sex: "female")
    second.update!(cpf: first.cpf)
    mine = pending_for(line, citizen: first)
    other = pending_for(line, citizen: second)
    result = CareLines::AcceptSuggestion.call(suggestion: mine, team: team, by: doctor, today: today)
    expect(result.payload[:enrollment]).to have_attributes(suggestion_id: mine.id, source: "suggestion")
    expect([ mine, other ].map { |s| s.reload.status }).to eq(%w[accepted accepted])
    expect(other.decided_by_user_id).to eq(doctor.id)
    expect(CareLineSuggestion.pending_suggestions).to be_empty
  end
end
