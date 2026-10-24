# Perfil do profissional de saúde (ADR 0021): 1:1 com o usuário. O papel
# health_professional continua sendo o que autoriza; o perfil diz quem é e,
# pelos vínculos, onde atua. CNS cifrado determinístico (unicidade); contato
# cifrado com a chave da cidade; registro do conselho em claro (dado público).
class Professional < ApplicationRecord
  COUNCILS = %w[CRM COREN CRO CRF CRP CREFITO CRN CRFa CRESS CRBM CREF CRMV].freeze
  UFS = %w[AC AL AP AM BA CE DF ES GO MA MT MS MG PA PB PR PE PI RJ RN RS RO RR SC SP SE TO].freeze
  FIELDS = %w[professional_name council council_state registration_number cns cpf phone contact_email].freeze
  # O profissional edita só nome e contato (emenda ao ADR 0021, 2026-09-27):
  # conselho, registro e CNS a prefeitura confere.
  SELF_EDITABLE = %w[professional_name phone contact_email].freeze

  encrypts :cns, deterministic: true, key_provider: CityDeterministicKeyProvider.new
  encrypts :cpf, deterministic: true, key_provider: CityDeterministicKeyProvider.new
  encrypts :phone
  encrypts :contact_email

  # ADR 0034 (Lei 5.991, art. 35): endereço do prescritor impresso na RCE e na
  # RET digitais; JSON cifrado com a chave da cidade. O telefone é o `phone`.
  encrypts :prescriber_address

  def prescriber_address_data
    data = prescriber_address.present? ? JSON.parse(prescriber_address) : nil
    data.is_a?(Hash) ? data : nil
  rescue JSON::ParserError
    nil
  end

  # { "address" => {…}, "phone" => "…" } só quando os dois existem.
  def prescriber_contact
    address = prescriber_address_data
    address && phone.present? ? { "address" => address, "phone" => phone } : nil
  end

  belongs_to :user
  has_many :links, class_name: "ProfessionalLink", dependent: :restrict_with_error

  normalizes :professional_name, with: ->(v) { v.to_s.squish }
  normalizes :council_state, with: ->(v) { v.to_s.strip.upcase }
  normalizes :registration_number, :cns, with: ->(v) { v.to_s.gsub(/\D/, "") }
  normalizes :cpf, with: ->(v) { v.to_s.gsub(/\D/, "").presence }, apply_to_nil: true
  normalizes :phone, with: ->(v) { v.to_s.gsub(/\D/, "").presence }, apply_to_nil: true
  normalizes :contact_email, with: ->(v) { v.to_s.strip.downcase.presence }, apply_to_nil: true

  validates :professional_name, presence: true
  # Profissionais de campo (ACS 515105, agente de endemias 515140; módulo
  # 24a) não têm conselho: conselho, UF e registro todos ou nenhum (CHECK
  # ck_professionals_council_all_or_none).
  validates :council, inclusion: { in: COUNCILS }, allow_nil: true
  validates :council_state, inclusion: { in: UFS }, allow_nil: true
  validates :registration_number, format: { with: /\A\d{1,10}\z/ }, allow_nil: true
  validate { errors.add(:council, :incomplete) unless [ council, council_state, registration_number ].compact.size.in?([ 0, 3 ]) }
  validates :phone, format: { with: /\A\d{10,11}\z/ }, allow_nil: true
  validates :contact_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_nil: true
  validate { errors.add(:cns, :invalid) unless Professionals::Cns.valid?(cns) }
  validate { errors.add(:cpf, :invalid) unless cpf.nil? || CitizenIdentity::Cpf.normalize(cpf) }

  def cns_masked = Professionals::Cns.mask(cns)
  def cpf_masked = cpf && CitizenIdentity::Cpf.mask(cpf)
end
