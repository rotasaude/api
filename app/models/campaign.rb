# app/models/campaign.rb
# Campanha da secretaria (ADR 0024): aviso na caixa do wpda para um público
# descrito em JSON (Campaigns::AudienceSchema) e congelado no envio
# (campaign_recipients). Escrita só pelos comandos de app/commands/campaigns;
# depois do envio, imutável (trigger campaigns_frozen_after_send).
class Campaign < ApplicationRecord
  STATUSES = %w[draft scheduled sending sent cancelled failed].freeze
  TITLE_LENGTH = 3..120
  BODY_LENGTH = 10..2000
  # Telefones distintos (D8, D12): um telefone pode ter vários CPFs.
  MINIMUM_PHONES = 5
  SEND_AT_MIN_LEAD = 5.minutes
  SEND_AT_MAX_AHEAD = 90.days

  belongs_to :created_by_user, class_name: "User"
  belongs_to :dispatched_by_user, class_name: "User", optional: true
  belongs_to :cancelled_by_user, class_name: "User", optional: true
  has_many :recipients, class_name: "CampaignRecipient", dependent: :restrict_with_error

  normalizes :title, with: ->(value) { value.to_s.strip }
  normalizes :body, with: ->(value) { value.to_s.strip }
end
