# Seam para múltiplos provedores de auth (ADR-0022). Hoje só 'password';
# 'govbr' entra como linha nova na mesma tabela.
class Identity < ApplicationRecord
  belongs_to :user
  validates :provider, :provider_uid, presence: true
  validates :provider_uid, uniqueness: { scope: :provider }
end
