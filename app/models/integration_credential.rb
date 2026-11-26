# app/models/integration_credential.rb
# Credencial de integração da cidade (ADR 0028; spec 2026-10-05 §3.3). Só o
# municipal_admin escreve (Integrations::SetCredential). O segredo é um Hash
# { "username", "password" } serializado em JSON e cifrado com a chave da
# cidade — `serialize` vem ANTES de `encrypts` (o tipo cifrado embrulha o
# serializado). Nunca aparece em resposta, log, evento ou argumento de job.
class IntegrationCredential < ApplicationRecord
  KINDS = %w[ledi cadsus rnds bnafar rnds_regulation].freeze
  # Ambiente da credencial (módulo 27b, Q9): só a bnafar tem homologação.
  ENVIRONMENTS = %w[homologation production].freeze
  # Chaves do segredo por tipo; ledi/cadsus { username, password }, rnds o
  # certificado A1 (PKCS#12 em base64), a senha e o CNES solicitante (ADR 0047).
  SECRET_KEYS = { "ledi" => %w[password username], "cadsus" => %w[password username],
                  "bnafar" => %w[password username],
                  "rnds" => %w[pfx_base64 pfx_password requester_cnes],
                  # Módulo 26c (Q13): a regulação na RNDS leva também o identificador
                  # do solicitante (só dígitos) e o CNS do responsável pelo envio.
                  "rnds_regulation" => %w[pfx_base64 pfx_password requester_cnes requester_id responsible_cns] }.freeze
  # Kinds com certificado A1 (PKCS#12) no segredo.
  PFX_KINDS = %w[rnds rnds_regulation].freeze
  REQUESTER_ID_FORMAT = /\A\d{1,20}\z/
  PFX_MAX_BYTES = 100 * 1024
  PFX_BASE64_MAX = ((PFX_MAX_BYTES + 2) / 3) * 4
  CNES_FORMAT = /\A\d{7}\z/
  STATUSES = %w[ok unauthorized unreachable error].freeze
  FIELD_MAX = 200

  serialize :secret, coder: JSON
  encrypts :secret

  belongs_to :set_by_user, class_name: "User"

  # As credenciais em uso (Q9): a `production` de cada tipo (ledi, cadsus e
  # rnds só têm essa) e a `bnafar` do ambiente em uso.
  scope :in_use, ->(bnafar_environment) { where("kind <> 'bnafar' OR environment = ?", bnafar_environment) }

  validates :kind, inclusion: { in: KINDS }, uniqueness: { scope: :environment }
  validates :environment, inclusion: { in: ENVIRONMENTS }
  validates :set_at, presence: true
  validates :last_check_status, inclusion: { in: STATUSES }, allow_nil: true
  validates :last_check_message, length: { maximum: FIELD_MAX }
  validate :secret_shape

  def username = secret.is_a?(Hash) ? secret["username"] : nil
  def password = secret.is_a?(Hash) ? secret["password"] : nil
  def pfx_password = secret.is_a?(Hash) ? secret["pfx_password"] : nil
  def requester_cnes = secret.is_a?(Hash) ? secret["requester_cnes"] : nil
  def requester_id = secret.is_a?(Hash) ? secret["requester_id"] : nil
  def responsible_cns = secret.is_a?(Hash) ? secret["responsible_cns"] : nil

  # DER do PKCS#12 (binário), ou nil se o segredo não for de rnds.
  def pfx_bytes
    encoded = secret.is_a?(Hash) ? secret["pfx_base64"] : nil
    encoded.is_a?(String) ? Base64.strict_decode64(encoded) : nil
  rescue ArgumentError
    nil
  end

  def inspect = "#<IntegrationCredential id=#{id.inspect} kind=#{kind.inspect} last_check_status=#{last_check_status.inspect}>"

  private

  def secret_shape
    keys = SECRET_KEYS[kind]
    ok = keys && secret.is_a?(Hash) && secret.keys.sort == keys && secret.values.all?(String)
    ok &&= PFX_KINDS.include?(kind) ? rnds_shape? : secret.values.all? { |v| v.strip.present? && v.length <= FIELD_MAX }
    errors.add(:secret, :invalid) unless ok
  end

  def rnds_shape?
    secret["pfx_base64"].present? && secret["pfx_base64"].length <= PFX_BASE64_MAX &&
      secret["pfx_password"].length.between?(1, FIELD_MAX) && secret["requester_cnes"].match?(CNES_FORMAT) &&
      (kind != "rnds_regulation" || regulation_shape?)
  end

  def regulation_shape?
    secret["requester_id"].match?(REQUESTER_ID_FORMAT) && Professionals::Cns.valid?(secret["responsible_cns"])
  end
end
