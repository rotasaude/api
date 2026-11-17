# Ajustes da vigilância ambiental da cidade (módulo 35a; contrato §1, §4): uma
# linha só (id 1, CHECK), com o local de estoque que o boletim baixa (nulo =
# sem baixa). A migração não a insere; nasce sob demanda (current). Nunca é
# apagada (trigger).
class VectorControlSetting < ApplicationRecord
  self.primary_key = "id"

  belongs_to :stock_location, optional: true

  def self.current = find_by(id: 1) || (ensure_defaults! && find(1))

  # A linha vazia (sem local) se falta; nunca mexe na gravada.
  def self.ensure_defaults!(now: Time.current)
    insert_all([ { "id" => 1, "created_at" => now, "updated_at" => now } ], unique_by: :id)
    true
  end

  def inspect = "#<VectorControlSetting id=#{id} version=#{version}>"
end
