# Revogação (ADR 0024 §5.6): quando a conversa revogada é a mais recente do
# cidadão (created_at DESC, id DESC), as linhas dele em campaign_recipients
# são apagadas. Os contadores gravados na campanha não mudam; leitura e SMS
# são contados ao vivo e encolhem.
#
# Mesma regra de Campaigns::Audience::REVOKED_SQL (app/services/campaigns/audience.rb):
# a conversa mais recente do cidadão decide, com o mesmo desempate por id;
# ambos devem mudar juntos. Aqui a revogação vem afirmada pelo evento
# consent.revoked que aciona o consumidor, então não relemos o consentimento.
module Campaigns
  module ForgetRevokedRecipients
    def self.call(conversation_id:)
      conversation = Conversation.find_by(id: conversation_id)
      return 0 unless conversation&.citizen_id

      latest_id = Conversation.where(citizen_id: conversation.citizen_id)
                              .order(created_at: :desc, id: :desc).pick(:id)
      return 0 unless latest_id == conversation.id

      RecipientsFreezeLock.acquire!
      CampaignRecipient.where(citizen_id: conversation.citizen_id).delete_all
    end
  end
end
