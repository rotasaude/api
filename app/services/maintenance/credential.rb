# Quem está agindo na API de manutenção (spec §7).
#
# Existe para que "pode escrever?" e "alcança esta cidade?" tenham UMA resposta,
# em vez de cada resolver reimplementar a regra — foi assim que a spec escreveu
# o escopo do token, e é o que torna a guarda de analisador (Task 5) possível.
module Maintenance
  class Credential
    attr_reader :maintainer, :session, :token

    def self.session(session) = new(maintainer: session.maintainer, session: session)
    def self.token(token) = new(maintainer: token.maintainer, token: token)

    def initialize(maintainer:, session: nil, token: nil)
      @maintainer = maintainer
      @session = session
      @token = token
    end

    def human? = session.present?
    def token? = token.present?

    # Pessoa nunca é read-only: o mantenedor tem poderes totais (spec §5). O
    # recorte existe só para token.
    def read_only? = token? && token.read_only?

    def allows_city?(slug) = human? || token.allows_city?(slug)

    def audit_payload
      return MaintenanceAudit.credential_for(token: token) if token?

      MaintenanceAudit.credential_for(session: session)
    end
  end
end
