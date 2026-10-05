# Cidadão do canal web: o PAR (CPF, telefone), no banco da cidade. Ver spec
# 2026-09-22-web-citizen-channel §2. Um telefone serve a vários CPFs (a família
# que divide um celular) e um CPF aparece em vários telefones; quem junta os
# pares é a validação presencial (subprojeto 2).
class Citizen < ApplicationRecord
  MAX_PER_PHONE = 10

  encrypts :cpf,   deterministic: true, key_provider: CityDeterministicKeyProvider.new
  encrypts :phone, deterministic: true, key_provider: CityDeterministicKeyProvider.new

  # ADR 0027: perfil do par. Cifrado com a chave da cidade, NÃO determinístico
  # (nenhum é chave de busca). A idade nunca é gravada: Citizen#age calcula.
  SEXES = %w[female male].freeze
  GENDER_IDENTITIES = %w[cis_woman cis_man trans_woman trans_man travesti non_binary other].freeze
  PROFILE_SOURCES = %w[declared verified].freeze
  BIRTH_DATE_FORMAT = /\A\d{4}-\d{2}-\d{2}\z/

  encrypts :birth_date
  encrypts :sex
  encrypts :gender_identity

  has_many :conversations, dependent: :restrict_with_error
  has_many :verifications, class_name: "CitizenVerification", dependent: :restrict_with_error
  has_many :verification_codes, class_name: "CitizenVerificationCode", dependent: :restrict_with_error

  # ADR 0023: bairro declarado; nil = "prefiro não informar".
  belongs_to :neighborhood, optional: true

  # ADR 0024: preferências de contato e avisos recebidos.
  has_one :contact_preference, class_name: "CitizenContactPreference"
  has_many :campaign_recipients, dependent: :restrict_with_error

  enum :verification_level, { declared: "declared", verified: "verified" }, prefix: true

  validates :cpf, :phone, presence: true

  # O banco só vê texto cifrado: os valores são conferidos aqui (o CHECK do
  # banco cobre profile_source e o "tudo ou nada" do perfil).
  validates :sex, inclusion: { in: SEXES }, allow_nil: true
  validates :gender_identity, inclusion: { in: GENDER_IDENTITIES }, allow_nil: true
  validates :profile_source, inclusion: { in: PROFILE_SOURCES }, allow_nil: true
  validates :birth_date, format: { with: BIRTH_DATE_FORMAT }, allow_nil: true

  # ADR 0026: cadastro excluído vira lápide (erased_at); consultas de uso
  # corrente ignoram a lápide.
  scope :not_erased, -> { where(erased_at: nil) }

  # Anos completos em `on`. 29/02 faz aniversário em 01/03 nos anos comuns.
  def self.age_between(born_on, on)
    years = on.year - born_on.year
    years -= 1 if on.month < born_on.month || (on.month == born_on.month && on.day < born_on.day)
    years
  end

  def profile? = birth_date.present? && sex.present?

  # Fuso da cidade: dentro de CityConnection.with, Time.zone é o da cidade.
  def age(on: Time.zone.today)
    return nil if birth_date.blank?

    self.class.age_between(Date.iso8601(birth_date), on)
  rescue Date::Error
    nil
  end

  def profile_context(on: Time.zone.today) = { age: age(on: on), sex: sex }

  def cpf_masked
    CitizenIdentity::Cpf.mask(cpf)
  end

  def active_verification
    verifications.active.first
  end
end
