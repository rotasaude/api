# Tradução de respostas livres em intenção de consentimento + versão atual.
# Ver ADR-0012. Viés de cautela: dúvida em "sair" é menos pior que dúvida em "aceito".
module Consents
  GIVE_PATTERNS = [
    /\A\s*(sim|aceito|concordo|ok|de acordo)\s*\z/i
  ].freeze

  REVOKE_PATTERNS = [
    /\A\s*(n[aã]o|sair|parar|cancelar|revogar)\s*\z/i,
    /\bsair\b/i,
    /\bparar\b/i
  ].freeze

  # Palavras-parada explícitas no MEIO da triagem (F-02.2). NÃO inclui "não",
  # que é uma resposta booleana válida.
  CANCEL_PATTERNS = [
    /\A\s*(sair|parar|cancelar|encerrar)\s*\z/i
  ].freeze

  # IDs de payload dos botões interativos de consentimento (F-02.4).
  GIVE_ID   = "consent_give".freeze
  REVOKE_ID = "consent_revoke".freeze

  def self.interpret(text)
    return :unknown if text.nil? || text.strip.empty?
    return :give    if text == GIVE_ID
    return :revoke  if text == REVOKE_ID
    return :revoke  if REVOKE_PATTERNS.any? { |re| text.match?(re) }
    return :give    if GIVE_PATTERNS.any?  { |re| text.match?(re) }
    :unknown
  end

  def self.cancel?(text)
    return false if text.nil?
    CANCEL_PATTERNS.any? { |re| text.match?(re) }
  end

  def self.current_version(municipality_id)
    raise ArgumentError, "municipality_id obrigatório" if municipality_id.nil?
    # ConsentTerm vem no Phase 6; até lá, fallback ao schema atual (1).
    return Rails.application.credentials.dig(:policy, :version) || 1 unless defined?(ConsentTerm)
    ConsentTerm.where(municipality_id: municipality_id).maximum(:version) || 1
  end

  def self.policy_text_sha(version)
    text = Rails.application.credentials.dig(:policy, "v#{version}", :text).to_s
    Digest::SHA256.hexdigest(text)
  end

  # Para revisão clínica das interpretações que ficaram em :unknown.
  def self.uncertain_log(conversation_id:, text:)
    Rails.logger.info("[consents.uncertain] conversation=#{conversation_id} text=#{text.inspect}")
  end
end
