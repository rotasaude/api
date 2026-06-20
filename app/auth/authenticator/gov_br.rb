# Integração gov.br OIDC — RASCUNHO (ADR-0022, ponto em aberto).
#
# ESTADO: estrutura e seam prontos. HTTP exchange + JWT verification são
# stubs. Para produção:
#   1. Adicionar gem 'jwt' ao Gemfile.
#   2. Configurar credentials.govbr.{client_id, client_secret, issuer_url, redirect_uri}.
#   3. Implementar exchange_code (POST /authorize/token) e verify_id_token
#      (fetch JWKS, validar assinatura RSA).
#   4. Mapear `nivel_confianca` (bronze|prata|ouro) → role mínima (ADR-0022:
#      ouro obrigatório para protocol_publisher, prata para municipal_admin).
#   5. Implementar callback OIDC com state/PKCE (proteção CSRF).
#
# Para piloto-só-senha (estado atual do produto): este módulo NÃO é wired
# em SessionsController em produção. Só existe para validar o seam de
# Authenticator (ADR-0022). Specs mockam o HTTP.
module Authenticator
  module GovBr
    class IntegrationError < StandardError; end

    TOKEN_ENDPOINT_PATH = "/authorize/token".freeze

    # Trade `code` (do redirect OIDC) por id_token claims + cria/encontra User.
    # Retorna User (active) ou nil. Levanta IntegrationError em falha de rede
    # ou token inválido — caller decide se 500 ou redirect.
    def self.authenticate(code:)
      raise IntegrationError, "code vazio" if code.blank?

      claims = exchange_code_for_claims(code)
      uid    = claims.fetch("sub")              # CPF (gov.br usa CPF como sub)
      email  = claims["email"]
      name   = claims["name"]
      assurance = claims["amr"]&.first || claims["nivel_confianca"]  # bronze|prata|ouro

      user = find_or_provision_user(uid: uid, email: email, name: name)
      return nil unless user&.active?

      annotate_identity_assurance(user, uid, assurance) if assurance.present?
      user
    end

    # — Internals —————————————————————————————————————————

    # STUB: troca code por id_token + claims. Em produção:
    #   POST {issuer}/authorize/token
    #     grant_type=authorization_code, code=…, redirect_uri=…
    #   → id_token (JWT). Validar assinatura via JWKS e expirações.
    def self.exchange_code_for_claims(code)
      raise IntegrationError, "STUB: gov.br exchange não implementado. " \
        "Veja TODOs no header deste arquivo."
    end

    # Encontra User via Identity(provider='govbr', provider_uid=cpf).
    # Sem match → cria User + Identity. Email pode bater com password user
    # pré-existente: mesmo User ganha uma segunda Identity (govbr) sem mexer
    # no password_digest. Isso é o seam — gov.br entra sem reescrever.
    def self.find_or_provision_user(uid:, email:, name: nil)
      ApplicationRecord.connected_to(role: :admin) do
        identity = Identity.find_by(provider: "govbr", provider_uid: uid)
        return identity.user if identity

        user = email.present? ? User.find_by(email_address: email.downcase) : nil
        user ||= User.create!(
          email_address: email&.downcase || "govbr-#{uid}@placeholder.invalid",
          password: SecureRandom.base58(32)
        )
        Identity.create!(user: user, provider: "govbr", provider_uid: uid)
        user
      end
    end

    # Loga o selo associado ao login. Esse log pode virar coluna em
    # identities depois (versão evolui se assurance mudar).
    def self.annotate_identity_assurance(user, uid, assurance)
      Rails.logger.info("[govbr] user=#{user.id} uid=#{uid} assurance=#{assurance}")
      Platform.audit("identity.govbr_login", user_id: user.id, provider_uid: uid, assurance: assurance)
    end
  end
end
