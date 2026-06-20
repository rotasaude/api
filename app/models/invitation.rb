class Invitation < ApplicationRecord
  belongs_to :municipality, optional: true
  belongs_to :invited_by, class_name: "User"

  validates :email, :role, :token, :expires_at, presence: true
  validates :role, inclusion: { in: Membership::ROLES }

  scope :pending, -> { where(accepted_at: nil).where("expires_at > ?", Time.current) }

  def expired?
    expires_at <= Time.current
  end
end
