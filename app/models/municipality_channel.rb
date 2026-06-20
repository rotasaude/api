# Canal WhatsApp por município (ADR-0021). access_token via AR Encryption (ADR-0011/0024).
# RLS-exempt: tabela lida ANTES de saber o tenant.
class MunicipalityChannel < ApplicationRecord
  belongs_to :municipality
  encrypts :access_token

  scope :active, -> { where(active: true) }

  validates :phone_number_id, :waba_id, :display_phone_number, presence: true
  validates :phone_number_id, uniqueness: true
end
