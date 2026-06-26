# apps/api/app/models/membership.rb
# Memberships (ADR-0023). Append-only: revogar = end-date (revoked_at).
class Membership < ApplicationRecord
  ROLES = %w[platform_operator municipal_admin protocol_author protocol_publisher viewer].freeze

  belongs_to :user
  belongs_to :municipality, optional: true
  belongs_to :granted_by, class_name: "User", optional: true

  validates :role, inclusion: { in: ROLES }
  validates :granted_at, presence: true
  validate  :operator_is_global

  scope :active, -> { where(revoked_at: nil) }

  def operator?
    role == "platform_operator" && municipality_id.nil?
  end

  def revoke!(by: nil)
    return if revoked_at.present?
    update!(revoked_at: Time.current)
  end

  private

  def operator_is_global
    if role == "platform_operator" && municipality_id.present?
      errors.add(:municipality_id, "must be nil for platform_operator")
    end
  end
end
