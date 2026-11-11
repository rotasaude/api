# Relatório de gestão anual da ouvidoria (ADR 0051; contrato §11): um por ano,
# texto simples não cifrado (documento público). Publicado, grava a foto dos
# números e nunca mais muda (trigger); nunca é apagado.
class OmbudsmanAnnualReport < ApplicationRecord
  STATES = %w[draft published].freeze

  belongs_to :published_by_user, class_name: "User", optional: true

  def published? = state == "published"
end
