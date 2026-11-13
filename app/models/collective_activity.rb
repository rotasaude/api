# Atividade coletiva com ficha LEDI (módulo 24b, ADR 0052). Só muda a marca de
# engano (três campos, uma vez; trigger). Temas, públicos, práticas, procedimento
# e motivo do engano são cifrados com a chave da cidade (`serialize` ANTES de
# `encrypts`). Sem dado pessoal em inspect/to_s/as_json: só id e estado.
class CollectiveActivity < ApplicationRecord
  belongs_to :team, class_name: "HealthTeam"
  belongs_to :health_unit
  belongs_to :professional
  belongs_to :recorded_by_user, class_name: "User"
  belongs_to :place_health_unit, class_name: "HealthUnit", optional: true
  belongs_to :mistaken_by_user, class_name: "User", optional: true
  has_many :professionals, class_name: "CollectiveActivityProfessional", dependent: :restrict_with_error
  has_many :participants, class_name: "CollectiveActivityParticipant", dependent: :restrict_with_error

  serialize :meeting_topics, coder: JSON
  serialize :target_audience, coder: JSON
  serialize :health_topics, coder: JSON
  serialize :health_practices, coder: JSON
  serialize :procedure_code, coder: JSON
  encrypts :meeting_topics, :target_audience, :health_topics, :health_practices, :procedure_code, :mistaken_reason

  validates :activity_type, inclusion: { in: CollectiveActivities::Catalog::TYPES.to_a }
  validates :origin, inclusion: { in: HomeVisits::Catalog::ORIGINS }

  # Atividade não marcada por engano (as fontes da ficha e da linha do tempo).
  scope :valid, -> { where(mistaken_at: nil) }

  def mistaken? = mistaken_at.present?
  def state = mistaken? ? "mistaken" : "recorded"

  def inspect = "#<CollectiveActivity id=#{id} state=#{state}>"
  alias_method :to_s, :inspect
  def pretty_print(pp) = pp.text(inspect)

  def as_json(*) = { "id" => id, "state" => state }
end
