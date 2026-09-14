# apps/api/app/models/membership.rb
# Memberships (ADR-0012), no banco da cidade. Append-only: revogar = end-date (revoked_at).
# Só papéis locais: o operador de plataforma saiu desta tabela (Operator, na
# plataforma — spec banco-por-cidade §5), e com ele a coluna de município e o
# CHECK de operador global. ROLES espelha ck_memberships_role do db/city_schema.rb.
class Membership < ApplicationRecord
  ROLES = %w[municipal_admin protocol_author protocol_publisher viewer].freeze

  belongs_to :user
  belongs_to :granted_by, class_name: "User", optional: true

  validates :role, inclusion: { in: ROLES }
  validates :granted_at, presence: true

  scope :active, -> { where(revoked_at: nil) }

  def revoke!(by: nil)
    return if revoked_at.present?
    update!(revoked_at: Time.current)
  end
end
