require "rails_helper"

# Contrato §14 L30 (PROVA-3): territory_registration.exited com óbito encerra
# as inscrições ATIVAS da pessoa por `death` (CareLines::EndEnrollment, que
# aceita a sugestão de encerramento ligada e fecha o pedido vivo) e dispensa
# as sugestões PENDENTES dela em todas as linhas (as do par validado também);
# mudança não mexe em nada (a equipe da inscrição decide, L22). Idempotente.
RSpec.describe CareLines::RegistrationExitedJob, type: :job do
  before { registry_city! }

  let(:unit) { care_unit! }
  let(:doctor) { care_doctor!(unit) }
  let!(:team) { care_team!(unit, doctor) }
  let(:diabetes) { adopted_line!("diabetes_c4") }
  let(:hypertension) { adopted_line!("hypertension_c5") }
  let(:elderly) { adopted_line!("elderly_c6") }
  let(:household) { registry_household! }
  let(:acs) { registry_acs_of(household) }

  def person!
    patient = care_patient!(age: 70, sex: "male")
    registration = registry_registration!(patient: patient, household: household)
    enrollment = care_enrollment!(patient: patient, line: diabetes, team: team, by: doctor)
    closure = CareLineSuggestion.create!(patient: patient, care_line: diabetes, team: team, reason: "resolved_problem", enrollment: enrollment,
                                         evidence_ref: "care_line_enrollment:#{enrollment.id}")
    pending = CareLineSuggestion.create!(patient: patient, care_line: hypertension, team: team, reason: "age_sex")
    pair = CareLineSuggestion.create!(citizen: Citizen.where(patient_id: patient.id).first!, care_line: elderly, team: team, reason: "age_sex")
    { patient: patient, registration: registration, enrollment: enrollment, closure: closure, pending: pending, pair: pair }
  end

  def exit!(registration, reason)
    params = { "reason" => reason, "on" => Time.zone.today.iso8601 }
    params["death_on"] = Time.zone.today.iso8601 if reason == "death"
    expect(TerritoryRegistry::ExitRegistration.call(registration: registration.reload, params: params, by: acs)).to be_ok
    DomainEvent.where(name: "territory_registration.exited").where("payload->>'registration_id' = ?", registration.id).sole
  end

  def deliver(event, event_id: event.id)
    described_class.new.perform(event_id: event_id, event_name: event.name, city_slug: Current.city.slug, payload: event.payload)
  end

  it "o evento está ligado ao consumidor" do
    expect(DomainEvents.registry["territory_registration.exited"].map(&:job)).to eq([ "CareLines::RegistrationExitedJob" ])
  end

  it "óbito: inscrição ativa encerrada por death, sugestões pendentes dispensadas (as do par também), a de encerramento aceita" do
    s = person!
    other = person!
    event = exit!(s[:registration], "death")
    deliver(event)

    expect(s[:enrollment].reload).to have_attributes(status: "ended", ended_reason: "death", ended_by_user_id: acs.id)
    expect(s[:closure].reload).to have_attributes(status: "accepted", decided_by_user_id: acs.id)
    [ s[:pending], s[:pair] ].each do |suggestion|
      expect(suggestion.reload).to have_attributes(status: "dismissed", decided_by_user_id: acs.id,
                                                   dismiss_reason: CareLines::RegistrationExitedJob::DISMISS_REASON)
    end
    expect(other[:enrollment].reload.status).to eq("active")
    expect(other[:pending].reload.status).to eq("pending")
    expect(DomainEvent.where(name: "care_line_enrollment.ended").sole.payload)
      .to eq("care_line_enrollment_id" => s[:enrollment].id, "user_id" => acs.id)
    expect(DomainEvent.where(name: "care_line_suggestion.dismissed").map { |e| e.payload["care_line_suggestion_id"] })
      .to contain_exactly(s[:pending].id, s[:pair].id)
  end

  # Revisão I1: "a pessoa" do 23 é Patients::Pairs.of (ligado OU com o CPF
  # dele) — o par validado do wpda com o mesmo CPF e sem patient_id também.
  it "óbito: a sugestão do par validado com o mesmo CPF, ainda sem patient_id, também é dispensada" do
    citizen = verified_citizen!(exam_seq!)
    patient = Patient.create!(cpf: citizen.cpf, full_name: "Joana Ribeiro Lima", mother_name: "Rita Ribeiro Lima",
                              birth_date: "1950-03-01", sex: "female", race_color: "03")
    expect(citizen.reload.patient_id).to be_nil
    suggestion = CareLineSuggestion.create!(citizen: citizen, care_line: elderly, team: team, reason: "declared")
    registration = registry_registration!(patient: patient, household: household)
    deliver(exit!(registration, "death"))
    expect(suggestion.reload).to have_attributes(status: "dismissed", dismiss_reason: CareLines::RegistrationExitedJob::DISMISS_REASON)
  end

  # Revisão m1: com pedido vivo, as travas seguem unidade → cidadão →
  # sugestões → inscrição; o pedido da inscrição fecha como no 23.
  it "óbito com pedido vivo da inscrição: o pedido fecha (dismissed) e a sugestão é dispensada" do
    s = person!
    opened = CareLines::OpenAppointmentRequest.call(enrollment: s[:enrollment], by: doctor)
    expect(opened).to be_ok
    deliver(exit!(s[:registration], "death"))
    expect(opened.payload[:request].reload).to have_attributes(status: "closed", closed_reason: "dismissed")
    expect(s[:pending].reload.status).to eq("dismissed")
    expect(s[:enrollment].reload.ended_reason).to eq("death")
  end

  it "reentrega (mesmo evento ou outro com o mesmo cadastro): nada duplica" do
    s = person!
    event = exit!(s[:registration], "death")
    deliver(event)
    counts = -> { DomainEvent.where(name: %w[care_line_enrollment.ended care_line_suggestion.dismissed care_line_suggestion.accepted]).count }
    before = counts.call
    expect { deliver(event) }.not_to change(ProcessedEvent, :count)
    deliver(event, event_id: SecureRandom.uuid)
    expect(counts.call).to eq(before)
    expect(s[:enrollment].reload.ended_reason).to eq("death")
  end

  it "mudança: nada muda (a equipe da inscrição decide)" do
    s = person!
    deliver(exit!(s[:registration], "moved"))
    expect(s[:enrollment].reload.status).to eq("active")
    expect([ s[:closure], s[:pending], s[:pair] ].map { |suggestion| suggestion.reload.status }).to all(eq("pending"))
  end
end
