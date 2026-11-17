# Tarefa da coordenação de endemias (módulo 35a; contrato §1, §6 e §8):
# intensificação de ovitrampa (com a leitura e a ovitrampa dela, A-8: uma
# aberta por ovitrampa), caso residente fora ou caso do bloqueio sem imóvel.
# Uma referência só, a do tipo (CHECK): leitura, notificação ou bloqueio (o
# caso sem lugar nasce proposta própria, §8); a ovitrampa é a da leitura (FK
# composta). Só fecha, uma vez: open → done | dismissed
# (trigger); a nota é cifrada com a chave da cidade. Sem dado em
# inspect/to_s/as_json além de id e estado.
class VectorTask < ApplicationRecord
  STATES = %w[open done dismissed].freeze

  encrypts :closed_note

  belongs_to :ovitrap_reading, optional: true
  belongs_to :ovitrap, optional: true
  belongs_to :disease_notification, optional: true
  belongs_to :transmission_block, optional: true
  belongs_to :closed_by_user, class_name: "User", optional: true

  validates :kind, inclusion: { in: VectorControl::Catalog::TASK_KINDS }
  validates :state, inclusion: { in: STATES }

  scope :open_tasks, -> { where(state: "open") }

  def inspect = "#<VectorTask id=#{id} kind=#{kind} state=#{state}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id, "kind" => kind, "state" => state }
end
