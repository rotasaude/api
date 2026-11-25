# Ajustes do envio à BNAFAR da cidade (módulo 27b; contrato §3; Q9): uma linha
# só (id 1, CHECK). O ambiente em uso fora de produção (Bnafar::Environment), o
# primeiro dia enviado (`started_on`, gravado uma vez: trigger) e o mantenedor
# que trocou por último (uuid da plataforma, sem FK). A migração a insere; o
# banco carregado do dump nasce sem ela (ensure_defaults!). Nunca é apagada.
class BnafarSetting < ApplicationRecord
  self.primary_key = "id"

  def self.current = find_by(id: 1) || (ensure_defaults! && find(1))

  # A linha `production` se falta; nunca mexe na gravada.
  def self.ensure_defaults!(now: Time.current)
    insert_all([ { "id" => 1, "environment" => "production", "updated_at" => now } ], unique_by: :id)
    true
  end

  def inspect = "#<BnafarSetting id=#{id} environment=#{environment} started_on=#{started_on}>"
end
