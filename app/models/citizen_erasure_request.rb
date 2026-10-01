# ADR 0026: pedido de exclusão do cadastro (Art. 18). Só acréscimo; ver
# db/city_triggers.sql (citizen_erasure_requests_guard).
class CitizenErasureRequest < ApplicationRecord
  STATUSES = %w[pending confirmed rejected retained].freeze

  encrypts :cpf, deterministic: true, key_provider: CityDeterministicKeyProvider.new

  belongs_to :presented_citizen, class_name: "Citizen"
  belongs_to :requested_by_user, class_name: "User"
  belongs_to :decided_by_user, class_name: "User", optional: true

  validates :status, inclusion: { in: STATUSES }
  scope :pending, -> { where(status: "pending") }
end
