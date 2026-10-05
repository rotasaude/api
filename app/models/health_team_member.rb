# app/models/health_team_member.rb
# Profissional numa equipe, com o CBO do CNES (ADR 0028; spec 2026-10-05 §5).
# Encerrar grava ended_on; um vínculo ativo por profissional e equipe (índice
# único parcial).
class HealthTeamMember < ApplicationRecord
  belongs_to :professional
  belongs_to :health_team

  scope :active, -> { where(ended_on: nil) }

  validates :cbo_code, format: { with: /\A\d{6}\z/ }
  validates :started_on, presence: true
end
