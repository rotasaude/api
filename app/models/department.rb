# Setor da secretaria (ADR 0051): destino do encaminhamento da ouvidoria. Nunca
# é apagado (trigger): desativa-se. Nome único sem distinguir caixa (índice).
class Department < ApplicationRecord
  belongs_to :updated_by_user, class_name: "User"

  validates :name, length: Ombudsman::Catalog::NAME

  scope :active, -> { where(active: true) }
end
