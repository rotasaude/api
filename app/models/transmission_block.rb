# Bloqueio de transmissão de arbovirose (módulo 35a; contrato §1 e §8):
# proposto pelo job, confirmado (active) ou descartado (com motivo) pela
# coordenação, e encerrado (closed): proposed → active | dismissed e
# active → closed (trigger). O motivo do descarte é cifrado com a chave da
# cidade. Sem dado em inspect/to_s/as_json além de id e estado.
class TransmissionBlock < ApplicationRecord
  DISEASE_GROUPS = %w[arbovirus].freeze

  encrypts :dismissed_reason

  belongs_to :center_block, class_name: "CityBlock", optional: true
  belongs_to :confirmed_by_user, class_name: "User", optional: true
  has_many :areas, class_name: "TransmissionBlockArea", inverse_of: :transmission_block
  has_many :cases, class_name: "TransmissionBlockCase", inverse_of: :transmission_block
  has_many :cycles, class_name: "TransmissionBlockCycle", inverse_of: :transmission_block

  validates :status, inclusion: { in: VectorControl::Catalog::BLOCK_STATUSES }
  validates :disease_group, inclusion: { in: DISEASE_GROUPS }

  def inspect = "#<TransmissionBlock id=#{id} status=#{status} version=#{version}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id, "status" => status }
end
