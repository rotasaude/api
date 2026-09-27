# Perfil do profissional de saúde (ADR 0021): 1:1 com o usuário. O papel
# health_professional continua sendo o que autoriza; o perfil diz quem é e,
# pelos vínculos, onde atua. CNS cifrado determinístico (unicidade); contato
# cifrado com a chave da cidade; registro do conselho em claro (dado público).
class Professional < ApplicationRecord
  encrypts :cns, deterministic: true, key_provider: CityDeterministicKeyProvider.new
  encrypts :phone
  encrypts :contact_email

  belongs_to :user
  has_many :links, class_name: "ProfessionalLink", dependent: :restrict_with_error
end
