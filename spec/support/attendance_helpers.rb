module AttendanceHelpers
  def create_unit(name = "UBS Centro", kind: "ubs", active: true)
    HealthUnit.create!(name: name, kind: kind, active: active)
  end

  # Triagem web concluída do cidadão. Usa o protocolo padrão; a data de
  # conclusão pode ser deslocada para testar a janela de 3 dias.
  def completed_web_triage_for(citizen, completed_at: Time.current)
    create_default_protocol! unless ProtocolDefinition.exists?(name: StartTriage::DEFAULT_PROTOCOL_NAME, status: "active")
    started = Citizens::StartConversation.call(citizen: citizen, consent_version: Consents.current_version, session_id: "s").payload
    Citizens::SubmitAnswer.call(conversation: started[:conversation], answer: "false", idempotency_key: SecureRandom.uuid)
    triage = started[:triage].reload
    triage.update_columns(completed_at: completed_at)
    triage
  end
end

RSpec.configure { |c| c.include AttendanceHelpers }
