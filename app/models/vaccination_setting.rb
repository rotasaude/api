# Parâmetros da sala de vacina da cidade (ADR 0047): uma linha só (id 1,
# CHECK), com a data do go-live (Desvio 10). A migração a insere; o banco
# carregado do dump nasce sem ela (ensure_defaults!). Nunca é apagada (trigger).
class VaccinationSetting < ApplicationRecord
  self.primary_key = "id"

  belongs_to :updated_by_user, class_name: "User", optional: true

  def self.current = find_by(id: 1) || (ensure_defaults! && find(1))

  # A linha vazia (sem go-live) se falta; nunca mexe na gravada.
  def self.ensure_defaults!(now: Time.current)
    insert_all([ { "id" => 1, "updated_at" => now } ], unique_by: :id)
    true
  end
end
