require "rails_helper"

# ADR 0029 §5.2 + ADR 0026: revogar fecha o pedido de triagem aberto sem
# horário; pedido já marcado fica (o cidadão cancela se quiser); pedido fundido
# com triagem de outra conversa ainda consentida também fica.
RSpec.describe AppointmentRequests::CloseRevoked do
  before { Current.city = TEST_CITY_A; ensure_appointment_types! }
  after { Current.reset; Rails.cache.clear }

  let(:rule) { [ { "when" => { "gte" => ["outcome.score", 1] }, "appointment_type" => "consulta_medica", "priority" => "routine", "due_in_days" => 30 } ] }
  let(:par) { profiled_citizen!(age: 70) }

  def complete(protocol = "saude-do-idoso")
    started = start_for!(par, protocol).payload
    Citizens::SubmitAnswer.call(conversation: started[:conversation], answer: "true", idempotency_key: SecureRandom.uuid)
    started[:triage].reload
  end

  it "revogar fecha o pedido aberto da triagem como consent_revoked, com evento" do
    active_protocol!("saude-do-idoso", scheduling: rule)
    triage = complete
    RevokeConsent.call(conversation: triage.conversation, origin: "web")
    request = AppointmentRequest.find_by!(origin_triage_id: triage.id)
    expect(request).to have_attributes(status: "closed", closed_reason: "consent_revoked", closed_at: be_present)
    expect(DomainEvent.where(name: "appointment_request.closed").last.payload)
      .to eq("appointment_request_id" => request.id, "closed_reason" => "consent_revoked")
  end

  it "pedido fundido com triagem de outra conversa ainda consentida fica aberto; revogada a outra, fecha" do
    active_protocol!("saude-do-idoso", scheduling: rule)
    active_protocol!("saude-do-idoso-2", scheduling: rule)
    first = complete
    second = complete("saude-do-idoso-2")
    request = AppointmentRequest.find_by!(origin_triage_id: first.id)
    expect(request.request_triages.pluck(:triage_id)).to eq([ second.id ])

    RevokeConsent.call(conversation: first.conversation, origin: "web")
    expect(request.reload.status).to eq("open")

    # A ligação (não a origem) também leva ao pedido.
    RevokeConsent.call(conversation: second.conversation, origin: "web")
    expect(request.reload).to have_attributes(status: "closed", closed_reason: "consent_revoked")
  end

  it "pedido já marcado não fecha" do
    active_protocol!("saude-do-idoso", scheduling: rule)
    triage = complete
    request = AppointmentRequest.find_by!(origin_triage_id: triage.id)
    request.update!(status: "scheduled")
    RevokeConsent.call(conversation: triage.conversation, origin: "web")
    expect(request.reload.status).to eq("scheduled")
    expect(DomainEvent.where(name: "appointment_request.closed")).to be_empty
  end

  it "não toca no pedido de outra conversa sem ligação com a revogada" do
    active_protocol!("saude-do-idoso", scheduling: rule)
    other_rule = [ rule.first.merge("appointment_type" => "consulta_enfermagem") ]
    active_protocol!("saude-da-mulher", scheduling: other_rule)
    first = complete
    unrelated = complete("saude-da-mulher")
    RevokeConsent.call(conversation: first.conversation, origin: "web")
    expect(AppointmentRequest.find_by!(origin_triage_id: unrelated.id).status).to eq("open")
  end
end
