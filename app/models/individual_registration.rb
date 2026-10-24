# Cadastro individual (módulo 24a, ADR 0042): cabeçalho da última versão. Um
# ativo por paciente (índice único parcial); a saída (moved | death) acontece
# uma vez e congela o cadastro (trigger). registered_at/registered_by_user =
# instante e autor da última versão `save` (nunca a `exit`; `identity_refresh`
# não é mais gravada — L24). Recusa ("true"/"false") e número da DO cifrados.
class IndividualRegistration < ApplicationRecord
  encrypts :refused, :death_certificate

  belongs_to :patient
  belongs_to :team, class_name: "HealthTeam"
  belongs_to :micro_area, optional: true
  belongs_to :household, optional: true
  belongs_to :family, optional: true
  belongs_to :registered_by_user, class_name: "User"
  has_many :versions, -> { order(:version) }, class_name: "IndividualRegistrationVersion", foreign_key: :registration_id,
                                              dependent: :restrict_with_error, inverse_of: :registration

  scope :active_registrations, -> { where(exit_reason: nil) }

  validates :refused, inclusion: { in: %w[true false] }
  validates :exit_reason, inclusion: { in: TerritoryRegistry::Catalog::EXIT_REASONS }, allow_nil: true

  def refused? = refused == "true"

  # L24: a validação no posto mudou a identidade do paciente depois da última
  # versão (registered_at = o instante dela no cadastro ativo); a próxima
  # gravação a leva. Cadastro que saiu não espera revisão.
  def identity_review_pending? = exit_reason.nil? && identity_changed_at.present? && identity_changed_at > registered_at
  def exited? = exit_reason.present?

  def latest_version = versions.reorder(version: :desc).first

  def inspect = "#<IndividualRegistration id=#{id} patient_id=#{patient_id} team_id=#{team_id} household_id=#{household_id}>"
end
