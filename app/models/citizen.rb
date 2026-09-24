# Cidadão do canal web: o PAR (CPF, telefone), no banco da cidade. Ver spec
# 2026-09-22-web-citizen-channel §2. Um telefone serve a vários CPFs (a família
# que divide um celular) e um CPF aparece em vários telefones; quem junta os
# pares é a validação presencial (subprojeto 2).
class Citizen < ApplicationRecord
  MAX_PER_PHONE = 10

  encrypts :cpf,   deterministic: true, key_provider: CityDeterministicKeyProvider.new
  encrypts :phone, deterministic: true, key_provider: CityDeterministicKeyProvider.new

  has_many :conversations, dependent: :restrict_with_error
  has_many :verifications, class_name: "CitizenVerification", dependent: :restrict_with_error
  has_many :verification_codes, class_name: "CitizenVerificationCode", dependent: :restrict_with_error

  enum :verification_level, { declared: "declared", verified: "verified" }, prefix: true

  validates :cpf, :phone, presence: true

  def cpf_masked
    CitizenIdentity::Cpf.mask(cpf)
  end

  def active_verification
    verifications.active.first
  end
end
