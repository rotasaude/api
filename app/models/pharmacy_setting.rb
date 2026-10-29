# Parâmetros da farmácia da cidade (ADR 0045): uma linha só (id 1, CHECK). A
# migração a insere; o banco carregado do dump nasce sem ela
# (ensure_defaults!). Nunca é apagada (trigger).
class PharmacySetting < ApplicationRecord
  self.primary_key = "id"

  belongs_to :updated_by_user, class_name: "User", optional: true

  def self.current = find_by(id: 1) || (ensure_defaults! && find(1))

  # Os padrões de Pharmacy::Catalog se a linha falta; nunca mexe na gravada.
  def self.ensure_defaults!(now: Time.current)
    insert_all([ Pharmacy::Catalog::DEFAULT_SETTINGS.merge("id" => 1, "updated_at" => now) ], unique_by: :id)
    true
  end
end
