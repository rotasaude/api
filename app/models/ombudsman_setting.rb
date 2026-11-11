# Prazos e teto da ouvidoria da cidade (ADR 0051): uma linha só (id 1, CHECK)
# — dias de resposta, prorrogação, urgência, complemento, encaminhamento e sua
# prorrogação, aviso de vencimento e o teto diário da denúncia anônima. A
# migração a insere; o banco carregado do dump nasce sem ela
# (Ombudsman::Settings.ensure_defaults!, Q13). Nunca é apagada (trigger).
class OmbudsmanSetting < ApplicationRecord
  self.primary_key = "id"

  belongs_to :updated_by_user, class_name: "User", optional: true

  def self.current = find_by(id: 1) || (Ombudsman::Settings.ensure_defaults! && find(1))

  # A linha com os padrões do banco se falta; nunca mexe na gravada.
  def self.ensure_defaults!(now: Time.current)
    insert_all([ { "id" => 1, "updated_at" => now } ], unique_by: :id)
    true
  end
end
