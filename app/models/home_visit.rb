# Visita domiciliar (módulo 24b, ADR 0052). Só muda a retirada (três campos, uma
# vez, com a folha aberta; trigger). Motivos, medidas, observação e motivo da
# retirada são cifrados com a chave da cidade (`serialize` ANTES de `encrypts`).
# Sem dado pessoal em inspect/to_s/as_json: só id e estado.
class HomeVisit < ApplicationRecord
  belongs_to :home_visit_day
  belongs_to :household, optional: true
  belongs_to :family, optional: true
  belongs_to :patient, optional: true
  belongs_to :micro_area, optional: true
  belongs_to :recorded_by_user, class_name: "User"
  belongs_to :withdrawn_by_user, class_name: "User", optional: true

  serialize :reasons, coder: JSON
  serialize :measurements, coder: JSON
  encrypts :reasons, :measurements, :note, :withdrawal_reason

  validates :outcome, inclusion: { in: HomeVisits::Catalog::OUTCOMES.keys }
  validates :subject, inclusion: { in: HomeVisits::Catalog::SUBJECTS }
  validates :origin, inclusion: { in: HomeVisits::Catalog::ORIGINS }

  # Visita não retirada (as fontes da ficha, das linhas de cuidado e da linha do tempo).
  scope :valid, -> { where(withdrawn_at: nil) }

  def withdrawn? = withdrawn_at.present?
  def recorded? = !withdrawn?

  def inspect = "#<HomeVisit id=#{id} state=#{withdrawn? ? 'withdrawn' : 'recorded'}>"
  alias_method :to_s, :inspect
  def pretty_print(pp) = pp.text(inspect)

  def as_json(*) = { "id" => id, "state" => (withdrawn? ? "withdrawn" : "recorded") }
end
