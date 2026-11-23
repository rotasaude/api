# Campanha de vacinação antirrábica animal (módulo 35b, ADR 0054; contrato §1
# e §3). Uma só `open` por vez (único parcial); a etapa só anda
# planned → open → closed (trigger). Sem dado pessoal.
class RabiesCampaign < ApplicationRecord
  has_many :vaccinations, class_name: "RabiesVaccination", foreign_key: :campaign_id, inverse_of: :campaign, dependent: :restrict_with_error

  scope :open_campaigns, -> { where(stage: "open") }

  def inspect = "#<RabiesCampaign id=#{id} stage=#{stage}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
end
