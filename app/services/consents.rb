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

  def self.interpret(text)
    return :unknown if text.nil? || text.strip.empty?
    return :revoke  if REVOKE_PATTERNS.any? { |re| text.match?(re) }
    return :give    if GIVE_PATTERNS.any? { |re| text.match?(re) }
    :unknown
  end

  def self.current_version
    Rails.application.credentials.dig(:policy, :version) || 1
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
