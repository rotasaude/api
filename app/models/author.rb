# Autor de protocolos (equipe clínica). Stub mínimo — auth real vira ADR próprio.
class Author < ApplicationRecord
  belongs_to :municipality, optional: true

  encrypts :token, deterministic: true

  validates :email, presence: true, uniqueness: true
  validates :token, presence: true, uniqueness: true
end
