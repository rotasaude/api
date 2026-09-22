require "rotp"

# Matrícula em duas etapas do usuário da cidade (spec 2026-09-22-pending-
# authenticator-design §4): `start` PROPÕE um segredo, `confirm` PROMOVE.
#
# Enquanto não houver confirmação, o autenticador ativo continua valendo — é o
# que permite abandonar uma troca no meio sem ficar sem segundo fator, e o que
# impede quem tem só a senha de plantar um segredo e confirmá-lo (numa conta já
# cadastrada, MfaController#enroll exige step-up).
#
# Mantenedor e operador continuam em Mfa::Enroll: lá a matrícula nasce de um
# convite, e reenviar o convite É o caminho de recuperação.
module Mfa
  module PendingEnrollment
    RECOVERY_COUNT = 10
    RECOVERY_LEN   = 10
    TTL = 15.minutes

    def self.start(user)
      secret = ROTP::Base32.random
      codes  = Array.new(RECOVERY_COUNT) { SecureRandom.alphanumeric(RECOVERY_LEN).downcase }

      user.update!(
        otp_pending_secret: secret,
        # Mesmo custo de Mfa::Enroll (mínimo em teste): custo fixo 12 já levou
        # a suíte inteira a 10 minutos.
        otp_pending_recovery_codes: codes.map { |c| BCrypt::Password.create(c, cost: Mfa::Enroll.recovery_code_cost).to_s },
        otp_pending_at: Time.current
      )

      {
        otpauth_uri: ROTP::TOTP.new(secret, issuer: "Rota Saúde").provisioning_uri(user.email_address),
        recovery_codes: codes
      }
    end

    # :ok | :no_pending_enrollment | :enrollment_expired | :invalid_code | :code_reused
    def self.confirm(user, code:)
      return :no_pending_enrollment if user.otp_pending_secret.blank?

      if user.otp_pending_at.nil? || user.otp_pending_at <= TTL.ago
        clear!(user)
        return :enrollment_expired
      end

      # SÓ TOTP do pendente: um recovery code (do ativo ou do pendente) não
      # prova que o autenticador novo foi lido.
      step = Mfa::Verify.step_for_secret(user.otp_pending_secret, code)
      return :invalid_code unless step
      return :code_reused unless user.consume_totp_step!(step)

      user.update!(
        otp_secret: user.otp_pending_secret,
        otp_recovery_codes: user.otp_pending_recovery_codes,
        otp_enabled: true,
        otp_pending_secret: nil,
        otp_pending_recovery_codes: [],
        otp_pending_at: nil
      )
      :ok
    end

    def self.clear!(user)
      user.update!(otp_pending_secret: nil, otp_pending_recovery_codes: [], otp_pending_at: nil)
    end
  end
end
