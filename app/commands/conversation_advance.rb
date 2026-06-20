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
# Textos de UI hardcoded em pt-BR como PLACEHOLDERS. Mover para
# config/locales ou por município é decisão de produto separada (TODO).
class ConversationAdvance
  Result = Struct.new(:reply, keyword_init: true)

  DEFAULT_PROTOCOL_NAME = "triagem-respiratoria"

  # TODO: textos viram produto/localização separados.
  GREETING_TEXT = "Olá! Para começar uma triagem, preciso do seu consentimento para usar suas respostas. Você concorda? (sim/não)"
  CONSENT_PROMPT_TEXT = "Não entendi. Você concorda com o uso dos seus dados para uma triagem? (sim/não)"
  CONSENT_REVOKED_TEXT = "Consentimento revogado. Para retomar, envie \"olá\" a qualquer momento."
  CONSENT_FAILED_TEXT = "Não consegui registrar seu consentimento agora. Tente novamente."
  NO_PROTOCOL_TEXT = "No momento não temos um protocolo de triagem ativo nesta cidade."
  TRIAGEM_INVALID_ANSWER_TEXT = "Resposta inválida. Tente responder à pergunta anterior novamente."
  TRIAGEM_GENERIC_ERROR = "Não consegui processar agora."

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
    Result.new(reply: GREETING_TEXT)
  end

  def handle_awaiting_consent
    case Consents.interpret(text)
    when :give
      result = GiveConsent.call(
        conversation: @conversation,
        version: Consents.current_version(@conversation.municipality_id),
        evidence: { text: text, message_id: @inbound.message_id, channel: "whatsapp" }
      )
      return Result.new(reply: CONSENT_FAILED_TEXT) if result.failure?
      begin_triagem_and_ask
    when :revoke
      RevokeConsent.call(conversation: @conversation, reason: text)
      Result.new(reply: CONSENT_REVOKED_TEXT)
    else
      Result.new(reply: CONSENT_PROMPT_TEXT)
    end
  end

  def handle_consented
    triagem = active_triagem || begin_triagem_or_nil
    return Result.new(reply: NO_PROTOCOL_TEXT) unless triagem

    result = CompleteTriagem.call(triagem: triagem, answer: text)
    return Result.new(reply: reason_text(result.reason)) if result.failure?

    outcome = result.payload[:outcome]
    return Result.new(reply: nil) if outcome.terminal?

    # Próxima pergunta — placeholder. Conteúdo real vem do step.prompt
    # quando o motor de protocolos expor isso (ADR-0013 amplia).
    Result.new(reply: "Pergunta #{outcome.awaiting}: (responda)")
  end

  def active_triagem
    @conversation.triagens.where(status: :in_progress).order(created_at: :desc).first
  end

  def begin_triagem_and_ask
    triagem = begin_triagem_or_nil
    return Result.new(reply: NO_PROTOCOL_TEXT) unless triagem
    Result.new(reply: "Vamos começar. Pergunta #{triagem.current_step}: (responda)")
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

  def reason_text(reason)
    case reason
    when :invalid_answer then TRIAGEM_INVALID_ANSWER_TEXT
    when :no_consent     then CONSENT_PROMPT_TEXT
    else                      TRIAGEM_GENERIC_ERROR
    end
  end
end
