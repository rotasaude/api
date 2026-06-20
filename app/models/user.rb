# Usuário do Admin Console (operação/SRE/auditoria). Ver ADR-0019.
#
# Audiência DIFERENTE de Author (autoria clínica, ADR-0016). Não unifique
# sem ADR — RBAC e fluxos divergem.
class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy

  belongs_to :municipality, optional: true

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  validates :email_address, presence: true, uniqueness: { case_sensitive: false }
end
