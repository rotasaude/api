# Checagem comum de Enviar e Agendar (spec 2026-09-29 §5.2): público ainda
# válido e com 5 telefones ou mais. Devolve um Result de falha ou nil.
module Campaigns
  module SendGate
    def self.failure_for(campaign)
      errors = AudienceValidation.errors(campaign.audience)
      return Result.fail(:invalid_audience, details: { details: errors }) if errors.any?

      Result.fail(:below_minimum) if Audience.new(campaign.audience).below_minimum?
    end
  end
end
