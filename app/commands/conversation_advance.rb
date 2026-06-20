# Avança a máquina de estados da conversa quando uma mensagem nova chega.
# Ver ADR-0012 (consent), ADR-0013 (motor de protocolos), ADR-0010 (ingestão).
#
# Recebe conversation (já lockada pelo PIMJ) + inbound (InboundMessage).
# Retorna Result#reply: String com o texto a enviar de volta, ou nil quando
# o fluxo segue por evento (ex.: triagem.completed → NotifyCitizenJob entrega
# o link do snapshot por outro caminho).
#
# Estados do conversation (ADR-0021 emenda 0012):
#   greeting → awaiting_consent → consented → revoked (terminal)
#
# Textos em config/locales/conversation_advance.pt-BR.yml.
# Próxima pergunta usa o `prompt` do step real do motor de protocolos (ADR-0013).
class ConversationAdvance
  Result = Struct.new(:reply, keyword_init: true)

  DEFAULT_PROTOCOL_NAME = "triagem-respiratoria"

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
    Result.new(reply: t(:greeting))
  end

  def handle_awaiting_consent
    case Consents.interpret(text)
    when :give
      result = GiveConsent.call(
        conversation: @conversation,
        version: Consents.current_version(@conversation.municipality_id),
        evidence: { text: text, message_id: @inbound.message_id, channel: "whatsapp" }
      )
      return Result.new(reply: t(:consent_failed)) if result.failure?
      begin_triagem_and_ask
    when :revoke
      RevokeConsent.call(conversation: @conversation, reason: text)
      Result.new(reply: t(:consent_revoked))
    else
      Result.new(reply: t(:consent_prompt))
    end
  end

  def handle_consented
    triagem = active_triagem || begin_triagem_or_nil
    return Result.new(reply: t(:no_protocol)) unless triagem

    result = CompleteTriagem.call(triagem: triagem, answer: text)
    return Result.new(reply: reason_text(result.reason)) if result.failure?

    outcome = result.payload[:outcome]
    return Result.new(reply: nil) if outcome.terminal?

    triagem.reload
    Result.new(reply: t(:triagem_next, prompt: step_prompt(triagem, outcome.awaiting)))
  end

  def active_triagem
    @conversation.triagens.where(status: :in_progress).order(created_at: :desc).first
  end

  def begin_triagem_and_ask
    triagem = begin_triagem_or_nil
    return Result.new(reply: t(:no_protocol)) unless triagem
    Result.new(reply: t(:triagem_start, prompt: step_prompt(triagem, triagem.current_step)))
  end

  def begin_triagem_or_nil
    record = ProtocolDefinition.where(
      municipality_id: @conversation.municipality_id,
      name: DEFAULT_PROTOCOL_NAME,
      status: "active"
    ).first
    return nil unless record

    engine = Protocols.current(@conversation.municipality_id, name: DEFAULT_PROTOCOL_NAME)
    @conversation.triagens.create!(
      protocol_definition: record,
      protocol_name: record.name,
      answers: {},
      current_step: engine.start_step_id.to_s,
      status: :in_progress
    )
  rescue Protocols::NotFound
    nil
  end

  def step_prompt(triagem, step_id)
    step = triagem.protocol.steps[step_id.to_sym]
    return t(:triagem_generic_error) unless step
    step.prompt
  end

  def reason_text(reason)
    case reason
    when :invalid_answer then t(:triagem_invalid_answer)
    when :no_consent     then t(:consent_prompt)
    else                      t(:triagem_generic_error)
    end
  end
end
