# Leitura da ovitrampa (módulo 35a; contrato §1 e §6): a palheta instalada,
# coletada uma vez (com a condição) e contada só se boa (CHECK). Uma aberta
# por ovitrampa (idx_ovitrap_readings_open). epi_week é inteira YYYYWW (A-9,
# Surveillance::EpiWeek de installed_on). A contagem vai de NULL a valor sem
# nota e só é corrigida com nota nova (trigger); a nota é cifrada com a chave
# da cidade. Sem dado em inspect/to_s/as_json além de id e estado.
class OvitrapReading < ApplicationRecord
  encrypts :count_note

  belongs_to :ovitrap, inverse_of: :readings
  belongs_to :counted_by_user, class_name: "User", optional: true

  validates :condition, inclusion: { in: VectorControl::Catalog::CONDITIONS }, allow_nil: true

  scope :open_readings, -> { where(collected_on: nil) }
  scope :pending_counts, -> { where(condition: "ok", egg_count: nil) }

  def inspect = "#<OvitrapReading id=#{id} ovitrap_id=#{ovitrap_id} condition=#{condition.inspect}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
