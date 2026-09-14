class Invitation < ApplicationRecord
  # Nulo quando o convite vem da plataforma: o primeiro municipal_admin de uma
  # cidade recém-provisionada (Plano 4).
  belongs_to :invited_by, class_name: "User", optional: true

  validates :email, :role, :token, :expires_at, presence: true
  validates :role, inclusion: { in: Membership::ROLES }

  scope :pending, -> { where(accepted_at: nil).where("expires_at > ?", Time.current) }

  def expired?
    expires_at <= Time.current
  end
end
