# A consulta da APS (ADR 0031; spec §4): uma por atendimento, do profissional
# que chamou. Rascunho (salvo automaticamente, só do autor; itens em
# draft_items) → finalizada, imutável (trigger); correção é adendo. S, O, A, P
# cifrados com a chave da cidade; sinais vitais com os limites do módulo 18.
class Consultation < ApplicationRecord
  STATUSES = %w[draft finalized].freeze
  TEXT_FIELDS = %w[subjective objective assessment plan].freeze
  MAX_TEXT = 20_000
  VITAL_COLUMNS = ScreeningRevision::VITAL_COLUMNS

  encrypts :subjective, :objective, :assessment, :plan

  belongs_to :attendance
  belongs_to :patient
  belongs_to :author_user, class_name: "User"
  belongs_to :professional_link
  has_many :problem_items, class_name: "ConsultationProblem", dependent: :restrict_with_error
  has_many :conducts, class_name: "ConsultationConduct", dependent: :restrict_with_error
  has_many :exam_requests, class_name: "ConsultationExamRequest", dependent: :restrict_with_error
  has_many :addenda, class_name: "ConsultationAddendum", dependent: :restrict_with_error

  scope :finalized_consultations, -> { where(status: "finalized") }

  def draft? = status == "draft"
  def finalized? = status == "finalized"

  def vitals = VITAL_COLUMNS.to_h { |column| [ column, self[column] ] }.compact
end
