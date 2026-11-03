# Checagem comum de Enviar e Agendar (spec 2026-09-29 §5.2): público ainda
# válido e com 5 telefones ou mais. Devolve um Result de falha ou nil.
module Campaigns
  module SendGate
    # `vaccination`: interruptor lido pelo comando ANTES da transação (O40);
    # veja SendGate.vaccination_for.
    def self.vaccination_for(campaign) = AudienceValidation.vaccination_usable?(campaign.audience)

    def self.failure_for(campaign, vaccination:)
      errors = AudienceValidation.errors(campaign.audience, vaccination: vaccination)
      return AudienceValidation.failure(errors) if errors.any?

      Result.fail(:below_minimum) if Audience.new(campaign.audience).below_minimum?
    end
  end
end
