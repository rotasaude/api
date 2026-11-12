# Folha do dia da visita domiciliar (módulo 24b, ADR 0052): a fonte da ficha LEDI
# tipo 8. Abre implicitamente na primeira visita do (profissional, equipe, dia) e
# fecha uma vez (dono, job ou cheia); fechada, congela (trigger).
class HomeVisitDay < ApplicationRecord
  STATES = %w[open closed].freeze

  belongs_to :professional
  belongs_to :user
  belongs_to :team, class_name: "HealthTeam"
  belongs_to :closed_by_user, class_name: "User", optional: true
  has_many :home_visits, dependent: :restrict_with_error

  validates :state, inclusion: { in: STATES }
  validates :closed_by, inclusion: { in: HomeVisits::Catalog::CLOSED_BY }, allow_nil: true
  validates :sequence, numericality: { only_integer: true, greater_than_or_equal_to: 1 }

  scope :open_on, ->(professional, team, day) { where(state: "open", professional: professional, team: team, day: day) }

  def open? = state == "open"
  def closed? = state == "closed"

  # AAAAMM do dia (a competência da ficha e do prazo do SIAPS).
  def competence = day.strftime("%Y%m")

  def inspect = "#<HomeVisitDay id=#{id} state=#{state}>"
  alias_method :to_s, :inspect
  def pretty_print(pp) = pp.text(inspect)
end
