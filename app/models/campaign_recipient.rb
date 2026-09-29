# app/models/campaign_recipient.rb
# Um cidadão do público congelado (ADR 0024 §3.2). Só mudam a leitura do aviso
# e o estado do SMS (trigger campaign_recipients_append_only); a revogação
# apaga a linha. Sem updated_at, de propósito.
class CampaignRecipient < ApplicationRecord
  SMS_STATUSES = %w[not_opted_in duplicate_phone pending deferred sent failed unavailable].freeze

  belongs_to :campaign
  belongs_to :citizen
end
