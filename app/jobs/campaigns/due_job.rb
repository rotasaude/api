# Agendados que venceram (ADR 0024; spec 2026-09-29 §5.2). Recorrente, a cada
# minuto, em cada cidade (EachCityJob). FOR UPDATE SKIP LOCKED: duas execuções
# concorrentes não pegam a mesma linha, e o PostgreSQL reavalia o
# status = 'scheduled' depois do lock — quem cancelou ou desagendou antes
# vence. O DispatchJob também é idempotente (só age em sending).
module Campaigns
  class DueJob < ApplicationJob
    prepend EachCityJob
    queue_as :default

    def perform
      ApplicationRecord.transaction do
        due = Campaign.where(status: "scheduled").where(send_at: ..Time.current)
                      .order(:send_at, :id).lock("FOR UPDATE SKIP LOCKED").to_a
        due.each do |campaign|
          campaign.update!(status: "sending")
          DispatchJob.perform_later(city_slug: Current.city.slug, campaign_id: campaign.id)
        end
      end
    end
  end
end
