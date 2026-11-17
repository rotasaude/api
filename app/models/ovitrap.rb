# Ovitrampa (módulo 35a, ADR 0054; contrato §1 e §6): instalada num domicílio,
# com o consentimento do morador e o quarteirão congelado na instalação. O
# número é único entre as ativas, sem caixa (idx_ovitraps_number); a removida
# ou perdida tem data de retirada (CHECK). Do app ⇔ com aparelho e
# client_uuid (o item ovitrap_installation). Nunca apagada (trigger).
class Ovitrap < ApplicationRecord
  STATUSES = %w[active removed lost].freeze
  ORIGINS = %w[dashboard field_app].freeze

  belongs_to :household
  belongs_to :city_block, optional: true
  belongs_to :installed_by_user, class_name: "User"
  belongs_to :field_device, optional: true
  has_many :readings, class_name: "OvitrapReading", inverse_of: :ovitrap

  validates :number, format: { with: VectorControl::Catalog::OVITRAP_NUMBER }
  validates :status, inclusion: { in: STATUSES }
  validates :origin, inclusion: { in: ORIGINS }

  scope :active_ovitraps, -> { where(status: "active") }

  def inspect = "#<Ovitrap id=#{id} number=#{number} status=#{status} version=#{version}>"
end
