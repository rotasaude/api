# O paciente do prontuário (ADR 0031; spec §3): um por CPF, criado na primeira
# consulta de um par VALIDADO; os pares validados do CPF se ligam a ele. Nome,
# nascimento e sexo vêm do par validado mais recente (Patients::Resolve). Tudo
# cifrado com a chave da cidade; o CPF determinístico (é chave de busca).
class Patient < ApplicationRecord
  encrypts :cpf, deterministic: true, key_provider: CityDeterministicKeyProvider.new
  encrypts :full_name
  encrypts :social_name
  encrypts :mother_name
  encrypts :birth_date
  encrypts :sex
  # D-U1 (ADR 0039; contrato §12): raça/cor (01..05, sem 99), etnia (só
  # indígena) e endereço do paciente para o BPA-I. Escritos pela recepção e
  # pelo faturista (Patients::Demographics); apagados na exclusão do cadastro.
  RACE_COLORS = %w[01 02 03 04 05].freeze
  DEMOGRAPHICS = %w[race_color ethnicity address_zip address_street address_number address_complement address_district].freeze
  encrypts :race_color, :ethnicity, :address_zip, :address_street, :address_number, :address_complement, :address_district

  has_many :citizens, dependent: :restrict_with_error
  has_many :problems, class_name: "PatientProblem", dependent: :restrict_with_error
  has_many :consultations, dependent: :restrict_with_error

  validates :cpf, presence: true

  def display_name = social_name.presence || full_name

  def cpf_masked = CitizenIdentity::Cpf.mask(cpf)

  def age(on: Time.zone.today)
    return nil if birth_date.blank?

    Citizen.age_between(Date.iso8601(birth_date), on)
  rescue Date::Error
    nil
  end
end
