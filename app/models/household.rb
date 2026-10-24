# Domicílio (módulo 24a, ADR 0042): cabeçalho da última versão. Cada gravação
# é uma HouseholdVersion imutável (fonte da ficha de cadastro domiciliar);
# version é a da última. registered_at/registered_by_user = instante e autor
# da última versão `save`. Nada se apaga (trigger).
class Household < ApplicationRecord
  STATUSES = %w[active inactive].freeze

  belongs_to :micro_area
  belongs_to :registered_by_user, class_name: "User"
  has_many :versions, -> { order(:version) }, class_name: "HouseholdVersion", dependent: :restrict_with_error,
                                              inverse_of: :household
  has_many :families, dependent: :restrict_with_error

  validates :status, inclusion: { in: STATUSES }

  def latest_version = versions.reorder(version: :desc).first

  def inspect = "#<Household id=#{id} micro_area_id=#{micro_area_id} version=#{version}>"
end
