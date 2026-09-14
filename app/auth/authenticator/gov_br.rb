# Integração gov.br OIDC (ADR-0011).
#
# Estado: estrutura completa. HTTP exchange + JWT verify implementados.
# Para ir a produção real:
#   1. Adicionar credentials.govbr.{client_id, client_secret, issuer_url, redirect_uri}.
#      Default issuer_url para teste: https://sso.staging.acesso.gov.br
#      Produção: https://sso.acesso.gov.br
#   2. A redirect_uri registrada no gov.br é o callback ÚNICO em auth.*
#      (GET /auth/govbr/callback, Govbr::CallbacksController — Plano 3B).
#   3. O login começa no host da cidade (POST /auth/govbr/start): o `state` é
#      assinado com a cidade e um nonce; o callback exige o mesmo nonce no id_token.
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
    AUTHORIZE_ENDPOINT_PATH = "/authorize".freeze
    STATE_PURPOSE = :govbr_state
    STATE_TTL = 10.minutes

    # ADR-0011: assurance → role mínima permitida (a maior).
    ASSURANCE_MIN_ROLE = {
      "bronze" => "viewer",
      "prata"  => "municipal_admin",
      "ouro"   => "platform_operator"
    }.freeze

    ROLE_RANK = %w[viewer protocol_author municipal_admin protocol_publisher platform_operator].freeze

    # URL de autorização do gov.br para a cidade `city`. O state (assinado, 10 min)
    # carrega a cidade e o nonce; o mesmo nonce vai para o gov.br e volta no id_token.
    def self.start(city:)
      nonce = SecureRandom.hex(16)
      state = state_verifier.generate({ "city" => city.slug, "nonce" => nonce },
                                      purpose: STATE_PURPOSE, expires_in: STATE_TTL)
      uri = URI.join(issuer_url, AUTHORIZE_ENDPOINT_PATH)
      uri.query = {
        response_type: "code", client_id: client_id, scope: "openid email profile",
        redirect_uri: redirect_uri, state: state, nonce: nonce
      }.to_query
      uri.to_s
    end

    def self.verify_state(state)
      return nil unless state.is_a?(String) && state.present?

      payload = state_verifier.verified(state, purpose: STATE_PURPOSE)
      return nil unless payload.is_a?(Hash) && payload["city"].is_a?(String) && payload["nonce"].is_a?(String)

      payload
    end

    # Roda NA conexão da cidade corrente (Govbr::CallbacksController abre
    # CityConnection.with e Current.set(city:)). Devolve nil para usuário desativado.
    def self.provision_from_claims(claims)
      uid       = claims.fetch("sub")
      assurance = claims["amr"]&.first || claims["nivel_confianca"]

      user = find_or_provision_user(uid: uid, email: claims["email"], name: claims["name"])
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
      raise IntegrationError, "code vazio" if code.blank?

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

    # Roda na conexão da cidade corrente (ver provision_from_claims).
    def self.find_or_provision_user(uid:, email:, name: nil)
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

    # Evento de domínio DA CIDADE (Ruling R18): no gov.br o provider_uid costuma
    # ser o CPF e não pode ir para o banco de plataforma. Mesmo na cidade, levá-lo
    # no payload é dívida de minimização registrada na R18, não resolvida aqui.
    def self.annotate_identity_assurance(user, uid, assurance)
      Rails.logger.info("[govbr] user=#{user.id} uid=#{uid} assurance=#{assurance}")
      ApplicationRecord.transaction do
        DomainEvents.publish("identity.govbr_login", user_id: user.id, provider_uid: uid, assurance: assurance)
      end
    end

    # — Configuration —————————————————————————————————————

    def self.state_verifier
      Rails.application.message_verifier(STATE_PURPOSE)
    end

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
