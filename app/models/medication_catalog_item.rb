# app/models/medication_catalog_item.rb
# Um medicamento do catálogo da plataforma (ADR 0033; spec §3): um por código
# CATMAT, estável, nunca apagado. `hidden` = fora da busca (revisão do
# analisador); `controlled` = bloqueado na receita (19d); `obm_code` reservado.
class MedicationCatalogItem < PlatformRecord
  PARSE_STATUSES = %w[ok review].freeze
  STATUSES = %w[active removed].freeze

  belongs_to :first_release, class_name: "MedicationCatalogRelease"
  belongs_to :last_release, class_name: "MedicationCatalogRelease"

  scope :prescribable, -> { where(status: "active", hidden: false) }

  def label = [ active_ingredient, strength, dosage_form ].compact_blank.join(" ")
  def ingredients = active_ingredient.split(" + ")
end
