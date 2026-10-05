# app/models/integration_credential.rb
# Credencial de integração da cidade (ADR 0028; spec 2026-10-05 §3.3). Só o
# municipal_admin escreve (Integrations::SetCredential). O segredo é um Hash
# { "username", "password" } serializado em JSON e cifrado com a chave da
# cidade — `serialize` vem ANTES de `encrypts` (o tipo cifrado embrulha o
# serializado). Nunca aparece em resposta, log, evento ou argumento de job.
class IntegrationCredential < ApplicationRecord
  KINDS = %w[ledi cadsus].freeze
  STATUSES = %w[ok unauthorized unreachable error].freeze
  FIELD_MAX = 200

  serialize :secret, coder: JSON
  encrypts :secret

  belongs_to :set_by_user, class_name: "User"

  validates :kind, inclusion: { in: KINDS }, uniqueness: true
  validates :set_at, presence: true
  validates :last_check_status, inclusion: { in: STATUSES }, allow_nil: true
  validates :last_check_message, length: { maximum: FIELD_MAX }
  validate :secret_shape

  def username = secret.is_a?(Hash) ? secret["username"] : nil
  def password = secret.is_a?(Hash) ? secret["password"] : nil

  def inspect = "#<IntegrationCredential id=#{id.inspect} kind=#{kind.inspect} last_check_status=#{last_check_status.inspect}>"

  private

  def secret_shape
    ok = secret.is_a?(Hash) && secret.keys.sort == %w[password username] &&
         secret.values.all? { |v| v.is_a?(String) && v.strip.present? && v.length <= FIELD_MAX }
    errors.add(:secret, :invalid) unless ok
  end
end
