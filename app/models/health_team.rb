# app/models/health_team.rb
# Equipe da APS (ADR 0028; spec 2026-10-05 §5): INE do CNES, tipo 70 (eSF) ou
# 76 (eAP), unidade onde atua. Nasce só pela confirmação de proposta do CNES
# (Cnes::Apply); desativar grava active=false, nada se apaga.
class HealthTeam < ApplicationRecord
  KINDS = %w[70 76].freeze

  belongs_to :health_unit
  has_many :members, class_name: "HealthTeamMember", dependent: :restrict_with_error

  validates :ine, format: { with: /\A\d{10}\z/ }, uniqueness: true
  validates :kind, inclusion: { in: KINDS }
  validates :name, length: { maximum: 120 }
end
