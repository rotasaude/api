# Avança a máquina de estados da conversa quando uma mensagem nova chega.
# Ver ADR-0012 (consent), ADR-0013 (motor de protocolos), ADR-0010 (ingestão).
#
# Recebe conversation (já lockada pelo PIMJ) + inbound (InboundMessage).
# Retorna Result#reply: Messaging::Reply (ou nil) com a resposta a enviar de volta,
# ou nil quando o fluxo segue por evento (ex.: triage.completed → NotifyCitizenJob
# entrega o link do snapshot por outro caminho).
#
# Estados do conversation (ADR-0021 emenda 0012):
#   greeting → awaiting_consent → consented → revoked (terminal)
#
# Textos em config/locales/conversation_advance.pt-BR.yml.
# Próxima pergunta usa o `prompt` do step real do motor de protocolos (ADR-0013).
class ConversationAdvance
  Result = Struct.new(:reply, keyword_init: true)

  DEFAULT_PROTOCOL_NAME = "triage-respiratoria"

  def self.call(conversation:, inbound:)
    new(conversation, inbound).call
  end

  def initialize(conversation, inbound)
    @conversation = conversation
    @inbound = inbound
  end

  def call
    case @conversation.state.to_sym
    when :greeting          then handle_greeting
    when :awaiting_consent  then handle_awaiting_consent
    when :consented         then handle_consented
    when :revoked           then Result.new(reply: nil)
    else                         Result.new(reply: nil)
    end
  end

  private

  def t(key, **vars)
    I18n.t("conversation_advance.#{key}", **vars)
  end

  def consent_reply(body)
    Messaging::Reply.buttons(
      body: body,
      options: [
        { id: Consents::GIVE_ID,   title: I18n.t("whatsapp.btn_yes") },
        { id: Consents::REVOKE_ID, title: I18n.t("whatsapp.btn_no") }
      ]
    )
  end

  def text
    @text ||= extract_body
  end

  def extract_body
    parsed = JSON.parse(@inbound.raw)
    Whatsapp::Ingest::Parser.extract_body(parsed).to_s
  rescue JSON::ParserError, TypeError
    ""
  end

  def handle_greeting
    @conversation.update!(state: :awaiting_consent)
    Result.new(reply: consent_reply(t(:greeting)))
  end

  def handle_awaiting_consent
    case Consents.interpret(text)
    when :give
      result = GiveConsent.call(
        conversation: @conversation,
        version: Consents.current_version(@conversation.municipality_id),
        evidence: { text: text, message_id: @inbound.message_id, channel: "whatsapp" }
      )
      return Result.new(reply: Messaging::Reply.text(t(:consent_failed))) if result.failure?
      begin_triage_and_ask
    when :revoke
      @conversation.update!(state: :declined)
      Result.new(reply: Messaging::Reply.text(t(:consent_declined)))
    else
      Result.new(reply: consent_reply(t(:consent_prompt)))
    end
  end

  def handle_consented
    return revoke_and_finish if Consents.revoke_intent?(text)
    return cancel_and_finish if Consents.cancel?(text)

    triage = active_triage || begin_triage_or_nil
    return Result.new(reply: Messaging::Reply.text(t(:no_protocol))) unless triage

    result = CompleteTriage.call(triage: triage, answer: text)
    return Result.new(reply: Messaging::Reply.text(reason_text(result.reason))) if result.failure?

    outcome = result.payload[:outcome]
    return complete_and_finish if outcome.terminal?

    triage.reload
    Result.new(reply: step_reply(triage, outcome.awaiting, :triage_next))
  end

  def active_triage
    @conversation.triages.where(status: :in_progress).order(created_at: :desc).first
  end

  def complete_and_finish
    @conversation.update!(state: :completed)
    Result.new(reply: nil)
  end

  def revoke_and_finish
    RevokeConsent.call(conversation: @conversation, reason: text)
    Result.new(reply: Messaging::Reply.text(t(:consent_revoked)))
  end

  def cancel_and_finish
    @conversation.triages.where(status: :in_progress)
                 .order(created_at: :desc).first&.update!(
                   status: :aborted_by_cancellation, completed_at: Time.current
                 )
    @conversation.update!(state: :cancelled)
    Result.new(reply: Messaging::Reply.text(t(:triage_cancelled)))
  end

  def begin_triage_and_ask
    triage = begin_triage_or_nil
    return Result.new(reply: Messaging::Reply.text(t(:no_protocol))) unless triage
    Result.new(reply: step_reply(triage, triage.current_step, :triage_start))
  end

  def begin_triage_or_nil
    record = ProtocolDefinition.where(
      municipality_id: @conversation.municipality_id,
      name: DEFAULT_PROTOCOL_NAME,
      status: "active"
    ).first
    return nil unless record

    engine = Protocols.current(@conversation.municipality_id, name: DEFAULT_PROTOCOL_NAME)
    @conversation.triages.create!(
      protocol_definition: record,
      protocol_name: record.name,
      answers: {},
      current_step: engine.start_step_id.to_s,
      status: :in_progress
    )
  rescue Protocols::NotFound
    nil
  end

  def step_reply(triage, step_id, template_key)
    step = triage.protocol.steps[step_id.to_sym]
    return Messaging::Reply.text(t(:triage_generic_error)) unless step
    body = t(template_key, prompt: step.prompt)
    Whatsapp::QuestionElement.for(step, body: body)
  end

  def reason_text(reason)
    case reason
    when :invalid_answer then t(:triage_invalid_answer)
    when :no_consent     then t(:consent_prompt)
    else                      t(:triage_generic_error)
    end
  end
end
