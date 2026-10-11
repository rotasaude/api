# A consulta da APS (ADR 0031; spec §4): uma por atendimento, do profissional
# que chamou. Rascunho (salvo automaticamente, só do autor; itens em
# draft_items) → finalizada, imutável (trigger); correção é adendo. S, O, A, P
# cifrados com a chave da cidade; sinais vitais com os limites do módulo 18.
# Rascunho órfão (card api#51): o admin municipal descarta (status
# `discarded`, conteúdo clínico zerado, a linha fica como casca) ou designa
# outro profissional — as duas escritas só sob with_draft_admin (trigger).
class Consultation < ApplicationRecord
  STATUSES = %w[draft finalized discarded].freeze
  TEXT_FIELDS = %w[subjective objective assessment plan].freeze
  MAX_TEXT = 20_000
  VITAL_COLUMNS = ScreeningRevision::VITAL_COLUMNS
  # O que o descarte zera (ck_consultations_discarded_empty); os itens do
  # rascunho (draft_items) também, pelo ck_consultations_draft_items.
  CLINICAL_COLUMNS = (TEXT_FIELDS + VITAL_COLUMNS).freeze
  LIST_LIMIT = 500

  encrypts :subjective, :objective, :assessment, :plan

  belongs_to :attendance
  belongs_to :patient
  belongs_to :author_user, class_name: "User"
  belongs_to :professional_link
  has_many :problem_items, class_name: "ConsultationProblem", dependent: :restrict_with_error
  has_many :conducts, class_name: "ConsultationConduct", dependent: :restrict_with_error
  has_many :exam_requests, class_name: "ConsultationExamRequest", dependent: :restrict_with_error
  has_many :addenda, class_name: "ConsultationAddendum", dependent: :restrict_with_error
  has_many :draft_actions, class_name: "ConsultationDraftAction", dependent: :restrict_with_error

  scope :finalized_consultations, -> { where(status: "finalized") }

  def draft? = status == "draft"
  def finalized? = status == "finalized"
  def discarded? = status == "discarded"

  # Marca rota.draft_admin (card api#51; db/city_triggers.sql): só dentro do
  # bloco o trigger aceita trocar a autora do rascunho, descartá-lo e trocar
  # quem chamou o atendimento in_care. Mesmo desenho de
  # CityEncryption.allowing_reencryption: savepoint próprio (abre a transação
  # se não houver); na falha, o ROLLBACK TO SAVEPOINT desfaz o SET LOCAL; no
  # sucesso o SET LOCAL sobreviveria ao RELEASE até o fim da transação externa,
  # por isso a marca volta a 'off' na mão (só no sucesso: depois de erro de SQL
  # a transação está abortada). Devolve o valor do bloco.
  def self.with_draft_admin
    connection = ApplicationRecord.connection
    ApplicationRecord.transaction(requires_new: true) do
      connection.execute("SET LOCAL rota.draft_admin = 'on'")
      failed = false
      begin
        yield
      rescue Exception # qualquer saída por erro (só marca e relança)
        failed = true
        raise
      ensure
        connection.execute("SET LOCAL rota.draft_admin = 'off'") unless failed
      end
    end
  end

  # As finalizadas de uma autora, mais novas primeiro, até LIST_LIMIT; o
  # período filtra finalized_at ("minhas consultas" e a leitura administrativa).
  def self.finalized_list(author_user_id:, from: nil, to: nil)
    scope = finalized_consultations.where(author_user_id: author_user_id).includes(:patient, attendance: :health_unit)
                                   .order(finalized_at: :desc, id: :desc).limit(LIST_LIMIT)
    scope = scope.where(finalized_at: from..) if from
    scope = scope.where(finalized_at: ..to) if to
    scope
  end

  def vitals = VITAL_COLUMNS.to_h { |column| [ column, self[column] ] }.compact
end
