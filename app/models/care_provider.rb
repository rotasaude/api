# Prestador da regulação (ADR 0044): a unidade da rede (own, com a unidade e o
# CNES dela, lido da unidade na hora do uso) ou um prestador externo (contratado, consórcio, PPI; CNES
# obrigatório). Nunca é apagado (trigger): desativa-se. Tipo, CNES e unidade
# são CHECKs do banco; a validação com mensagem é dos comandos.
class CareProvider < ApplicationRecord
  belongs_to :health_unit, optional: true
  belongs_to :updated_by_user, class_name: "User"
  has_many :offers, class_name: "CareOffer", inverse_of: :care_provider, dependent: :restrict_with_error

  scope :active_providers, -> { where(active: true) }

  # O CNES do prestador `own` é o da unidade, lido na hora (trocar o da unidade
  # vale logo, sem salvar o prestador); a coluna `cnes` só é gravada nos
  # externos (a cópia antiga nos `own` é ignorada). Unidade sem CNES → nil.
  def cnes = kind == "own" ? health_unit&.cnes : super
end
