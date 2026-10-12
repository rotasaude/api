require "openssl"

# Assinatura da chamada dos "sistemas externos" do e-SUS PEC (ADR 0035;
# docs/pesquisa/2026-10-11-pec-sistemas-externos.md): HMAC-SHA256 em hex da
# URL completa até antes de &pec_sign=, com a chave do cadastro do
# integrador. Compara em tempo constante; a janela é de 5 minutos para os dois
# lados; cada assinatura vale uma vez (pec_signature_uses, com o SHA-256 dela).
module PecExternal
  module Signature
    WINDOW = 300
    SIGN_PARAM = "&pec_sign=".freeze
    HEX = /\A\h{64}\z/
    TIMESTAMP = /\A\d{1,12}\z/

    module_function

    def verify(url:, key:, timestamp:, now: Time.current)
      unsigned, sign = url.to_s.split(SIGN_PARAM, 2)
      return :pec_signature_invalid unless key.is_a?(String) && key.present? && sign.to_s.match?(HEX)
      return :pec_signature_invalid unless timestamp.is_a?(String) && timestamp.match?(TIMESTAMP)
      return :pec_signature_invalid unless unsigned.end_with?("&pec_timestamp=#{timestamp}")

      expected = OpenSSL::HMAC.hexdigest("SHA256", key, unsigned)
      return :pec_signature_invalid unless ActiveSupport::SecurityUtils.secure_compare(expected, sign.downcase)
      return :pec_expired if (now.to_i - timestamp.to_i).abs > WINDOW

      consume!(sign.downcase, Time.zone.at(timestamp.to_i + WINDOW), now) ? :ok : :pec_replayed
    end

    # true se a assinatura ainda não tinha sido usada (INSERT ... ON CONFLICT DO NOTHING).
    def consume!(sign, expires_at, now)
      PecSignatureUse.where("expires_at < ?", now).delete_all
      PecSignatureUse.insert({ signature_digest: Digest::SHA256.hexdigest(sign), expires_at: expires_at, created_at: now },
                             unique_by: :signature_digest, returning: [ :id ]).rows.any?
    end
    private_class_method :consume!
  end
end
