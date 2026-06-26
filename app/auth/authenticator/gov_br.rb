# Integração gov.br OIDC (ADR-0022).
#
# Estado: estrutura completa. HTTP exchange + JWT verify implementados.
# Para ir a produção real:
#   1. Adicionar credentials.govbr.{client_id, client_secret, issuer_url, redirect_uri}.
#      Default issuer_url para teste: https://sso.staging.acesso.gov.br
#      Produção: https://sso.acesso.gov.br
#   2. Garantir callback /auth/govbr/callback é a redirect_uri registrada no gov.br.
#   3. Frontend deve enviar `state` + `nonce` (PKCE opcional) ao iniciar; backend
#      valida. Esta camada SÓ trata o exchange + verify do id_token; CSRF do
#      callback é responsabilidade do controller.
#   4. Mapping de assurance (bronze/prata/ouro) → role mínima nas policies.
#      Constants disponíveis em ASSURANCE_MIN_ROLE.
require "net/http"
require "jwt"
require "json"

module Authenticator
  module GovBr
    class IntegrationError < StandardError; end
    class InvalidIdToken < IntegrationError; end

    TOKEN_ENDPOINT_PATH = "/authorize/token".freeze
    JWKS_ENDPOINT_PATH  = "/jwk".freeze

    # ADR-0022: assurance → role mínima permitida (a maior).
    ASSURANCE_MIN_ROLE = {
      "bronze" => "viewer",
      "prata"  => "municipal_admin",
      "ouro"   => "platform_operator"
    }.freeze

    ROLE_RANK = %w[viewer protocol_author municipal_admin protocol_publisher platform_operator].freeze

    def self.authenticate(code:)
      raise IntegrationError, "code vazio" if code.blank?

      claims = exchange_code_for_claims(code)
      uid    = claims.fetch("sub")
      email  = claims["email"]
      name   = claims["name"]
      assurance = claims["amr"]&.first || claims["nivel_confianca"]

      user = find_or_provision_user(uid: uid, email: email, name: name)
      return nil unless user&.active?

      annotate_identity_assurance(user, uid, assurance) if assurance.present?
      user
    end

    # Verifica que `assurance` (do id_token) cobre o nível requerido por `role`.
    def self.assurance_meets?(assurance:, role:)
      return false if assurance.blank? || role.blank?
      min_role = ASSURANCE_MIN_ROLE[assurance.to_s]
      return false unless min_role
      role_idx = ROLE_RANK.index(role.to_s)
      min_idx  = ROLE_RANK.index(min_role)
      return false if role_idx.nil? || min_idx.nil?
      role_idx <= min_idx
    end

    # — Internals —————————————————————————————————————————

    def self.exchange_code_for_claims(code)
      token_response = fetch_token(code)
      id_token       = token_response.fetch("id_token") { raise IntegrationError, "no id_token" }
      decode_id_token(id_token)
    end

    def self.fetch_token(code)
      uri = URI.join(issuer_url, TOKEN_ENDPOINT_PATH)
      req = Net::HTTP::Post.new(uri, "Content-Type" => "application/x-www-form-urlencoded")
      req.basic_auth(client_id, client_secret)
      req.set_form_data(
        grant_type:   "authorization_code",
        code:         code,
        redirect_uri: redirect_uri
      )
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |h| h.request(req) }
      raise IntegrationError, "token endpoint http=#{res.code} body=#{res.body[0..200]}" unless res.code.to_i == 200
      JSON.parse(res.body)
    rescue JSON::ParserError, SocketError, Net::ReadTimeout, Net::OpenTimeout => e
      raise IntegrationError, "fetch_token: #{e.class}: #{e.message}"
    end

    def self.decode_id_token(token)
      jwks_loader = ->(_opts) { fetch_jwks_keys }
      claims, _header = JWT.decode(
        token, nil, true,
        algorithms: ["RS256"],
        jwks: jwks_loader,
        verify_iss: false,
        verify_aud: false
      )
      claims
    rescue JWT::DecodeError, JWT::VerificationError => e
      raise InvalidIdToken, "decode_id_token: #{e.class}: #{e.message}"
    end

    def self.fetch_jwks_keys
      uri = URI.join(issuer_url, JWKS_ENDPOINT_PATH)
      res = Net::HTTP.get_response(uri)
      raise IntegrationError, "jwks endpoint http=#{res.code}" unless res.code.to_i == 200
      JSON.parse(res.body).deep_symbolize_keys
    rescue JSON::ParserError => e
      raise IntegrationError, "fetch_jwks: #{e.message}"
    end

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

    def self.annotate_identity_assurance(user, uid, assurance)
      Rails.logger.info("[govbr] user=#{user.id} uid=#{uid} assurance=#{assurance}")
      Platform.audit("identity.govbr_login", user_id: user.id, provider_uid: uid, assurance: assurance)
    end

    # — Configuration —————————————————————————————————————

    def self.config
      Rails.application.credentials.dig(:govbr) || {}
    end

    def self.issuer_url
      config[:issuer_url] || ENV["GOVBR_ISSUER_URL"] || "https://sso.staging.acesso.gov.br"
    end

    def self.client_id
      config[:client_id] || ENV["GOVBR_CLIENT_ID"] || raise(IntegrationError, "missing GOVBR_CLIENT_ID")
    end

    def self.client_secret
      config[:client_secret] || ENV["GOVBR_CLIENT_SECRET"] || raise(IntegrationError, "missing GOVBR_CLIENT_SECRET")
    end

    def self.redirect_uri
      config[:redirect_uri] || ENV["GOVBR_REDIRECT_URI"] || raise(IntegrationError, "missing GOVBR_REDIRECT_URI")
    end
  end
end
