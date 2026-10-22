# app/models/care_line_suggestion.rb
# Sugestão (ADR 0040): de inscrição (problem | age_sex | declared) ou de
# encerramento (resolved_problem). Sem texto clínico; o motivo da recusa é
# cifrado. Só a equipe atribuída a vê.
class CareLineSuggestion < ApplicationRecord
  encrypts :dismiss_reason

  belongs_to :patient, optional: true
  belongs_to :citizen, optional: true
  belongs_to :care_line
  belongs_to :team, class_name: "HealthTeam"
  belongs_to :enrollment, class_name: "CareLineEnrollment", optional: true
  belongs_to :decided_by_user, class_name: "User", optional: true

  scope :pending_suggestions, -> { where(status: "pending") }

  def pending? = status == "pending"
  def closure? = reason == "resolved_problem"
end
