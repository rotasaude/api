# Ajustes do envio da regulação à RNDS da cidade (módulo 26c; Q6): uma linha só
# (id 1, CHECK; molde do BnafarSetting). O caráter por cor
# (`Regulation::RndsCatalog::DEFAULT_PRIORITY_BY_COLOR` por padrão), o SIGTAP
# por especialidade (CBO => SIGTAP), o envio dos pedidos regulados pelo estado
# (`send_external`), a versão (concorrência otimista: `expected_version`) e
# quem trocou por último. A migração a insere; o banco carregado do dump nasce
# sem ela (ensure_defaults!).
class RegulationRndsSetting < ApplicationRecord
  self.primary_key = "id"

  belongs_to :updated_by_user, class_name: "User", optional: true

  def self.current = find_by(id: 1) || (ensure_defaults! && find(1))

  # A linha com os padrões do banco se falta; nunca mexe na gravada.
  def self.ensure_defaults!(now: Time.current)
    insert_all([ { "id" => 1, "updated_at" => now } ], unique_by: :id)
    true
  end

  def inspect = "#<RegulationRndsSetting id=#{id} version=#{version} send_external=#{send_external}>"
end
