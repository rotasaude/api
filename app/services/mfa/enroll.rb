require "rotp"

module Mfa
  module Enroll
    RECOVERY_COUNT = 10
    RECOVERY_LEN   = 10

    # `recovery_codes:` decide se a matrícula emite o segundo fator ESTÁTICO.
    # User/Operator continuam com os dez códigos de sempre (default true); o
    # mantenedor entra com `false` (spec §6: "Não há recovery codes" — a
    # recuperação é outro mantenedor reenviar o convite). Um código de
    # recuperação é uma senha permanente que autentica sozinha no lugar do TOTP:
    # numa conta de poder total, isso anula o segundo fator.
    def self.call(user, recovery_codes: true)
      secret = ROTP::Base32.random
      codes  = recovery_codes ? Array.new(RECOVERY_COUNT) { SecureRandom.alphanumeric(RECOVERY_LEN).downcase } : []
      hashed = codes.map { |c| BCrypt::Password.create(c, cost: recovery_code_cost).to_s }

      # `otp_enabled` só existe em User/Operator: Maintainer marca a confirmação
      # do TOTP em `otp_enabled_at` (Task 2), então este call não a toca.
      attrs = { otp_secret: secret, otp_recovery_codes: hashed }
      attrs[:otp_enabled] = false if user.respond_to?(:otp_enabled=)
      user.update!(attrs)

      result = {
        secret: secret,
        otpauth_uri: ROTP::TOTP.new(secret, issuer: "Rota Saúde").provisioning_uri(user.email_address)
      }
      # Sem a chave, e não com a chave vazia: quem não emite código não devolve
      # nada para um controller repassar por engano.
      result[:recovery_codes] = codes if recovery_codes
      result
    end

    # A mesma política de custo que o Rails aplica à senha (has_secure_password):
    # custo mínimo quando ActiveModel::SecurePassword.min_cost está ligado (o
    # ambiente de teste), o custo padrão do BCrypt em qualquer outro caso.
    def self.recovery_code_cost
      ActiveModel::SecurePassword.min_cost ? BCrypt::Engine::MIN_COST : BCrypt::Engine.cost
    end
  end
end
