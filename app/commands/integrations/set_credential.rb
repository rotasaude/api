# app/commands/integrations/set_credential.rb
# Cadastra ou troca a credencial de integração da cidade (ADR 0028; spec
# 2026-10-05 §3.3; ADR 0047). Escrita só: nada devolve o segredo. Trocar zera o
# último teste. `secret` é o Hash do corpo: ledi/cadsus { username, password };
# rnds { pfx_base64, pfx_password, requester_cnes }. O evento leva só kind e
# user_id; a trilha da plataforma (rnds.credential_set) só city_id. O PFX é
# aberto aqui, nunca a mensagem da exceção é repassada.
# Reasons: :unknown_kind, :invalid_credential, :invalid_requester_cnes,
# :invalid_certificate, :certificate_expired.
module Integrations
  module SetCredential
    module_function

    def call(kind:, secret:, by:, city:)
      return Result.fail(:unknown_kind) unless IntegrationCredential::KINDS.include?(kind)

      secret = secret.respond_to?(:to_h) ? secret.to_h.stringify_keys : nil
      reason = kind == "rnds" ? validate_rnds(secret) : validate_login(secret)
      return Result.fail(reason) if reason

      stored = kind == "rnds" ? secret.slice(*IntegrationCredential::SECRET_KEYS["rnds"]) : login_secret(secret)
      credential = nil
      ApplicationRecord.transaction do
        credential = IntegrationCredential.lock.find_or_initialize_by(kind: kind)
        credential.update!(secret: stored, set_by_user: by,
                           set_at: Time.current, last_check_at: nil, last_check_status: nil, last_check_message: nil)
        DomainEvents.publish("integration_credential.changed", kind: kind, user_id: by.id)
      end
      Platform.audit("rnds.credential_set", city_id: city.id) if kind == "rnds"
      Result.ok(credential: credential)
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def validate_login(secret)
      return :invalid_credential unless secret && %w[username password].all? { |k| filled?(secret[k]) }
    end

    def login_secret(secret) = { "username" => secret["username"].strip, "password" => secret["password"] }

    # Forma (incl. 100 KB DECODIFICADOS) → invalid_credential; CNES →
    # invalid_requester_cnes; abre com a senha → invalid_certificate; vencido →
    # certificate_expired.
    def validate_rnds(secret)
      return :invalid_credential unless secret && secret.values_at("pfx_base64", "pfx_password", "requester_cnes").all?(String)

      encoded = secret["pfx_base64"]
      return :invalid_credential if encoded.empty? || encoded.length > IntegrationCredential::PFX_BASE64_MAX
      return :invalid_credential unless secret["pfx_password"].length.between?(1, IntegrationCredential::FIELD_MAX)

      der = begin
        Base64.strict_decode64(encoded)
      rescue ArgumentError
        return :invalid_credential
      end
      return :invalid_credential if der.empty? || der.bytesize > IntegrationCredential::PFX_MAX_BYTES
      return :invalid_requester_cnes unless secret["requester_cnes"].match?(IntegrationCredential::CNES_FORMAT)

      certificate_problem(der, secret["pfx_password"])
    end

    # nil quando o PFX abre com a senha e o certificado não venceu. Senha com
    # byte NUL (ArgumentError) ou tipo que o OpenSSL recusa (TypeError) também
    # é invalid_certificate; a mensagem da exceção nunca sai.
    def certificate_problem(der, password)
      return :invalid_certificate if der.nil? || password.nil?

      certificate = OpenSSL::PKCS12.new(der, password).certificate
      return :invalid_certificate if certificate.nil?

      :certificate_expired if certificate.not_after <= Time.current
    rescue OpenSSL::PKCS12::PKCS12Error, OpenSSL::OpenSSLError, ArgumentError, TypeError
      :invalid_certificate
    end

    def filled?(value) = value.is_a?(String) && value.strip.present? && value.length <= IntegrationCredential::FIELD_MAX
  end
end
