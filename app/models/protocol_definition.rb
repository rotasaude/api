# Storage de definições de protocolo. Ver ADR-0009 (Protocol engine).
# Toda a lógica do motor vive em Protocols::Protocol (puro) — este model é
# apenas armazenamento + lifecycle per-cidade. Dois eixos no campo `status`:
# autoria (draft → in_review → published) e vigência (published → active),
# com `retired` ao fim. `published` ≠ `active`.
class ProtocolDefinition < ApplicationRecord
  belongs_to :municipality, optional: true
  has_many   :triagens, dependent: :restrict_with_error

  validates :name, :version, :definition, :status, presence: true
  validates :version, uniqueness: { scope: [:name, :municipality_id] }
  validates :status, inclusion: { in: %w[draft in_review published active retired] }

  scope :active, -> { where(status: "active") }
  scope :published, -> { where(status: "published") }

  before_save :validate_definition_shape

  after_commit :invalidate_cache, if: :saved_change_to_status?

  private

  def validate_definition_shape
    result = Protocols::Validator.call(definition)
    return if result.valid?
    errors.add(:definition, result.errors.join("; "))
    throw :abort
  end

  def invalidate_cache
    Rails.cache.delete_matched("protocols.current/#{name}/*")
  end
end
