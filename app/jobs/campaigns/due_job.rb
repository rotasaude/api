# Agendados que venceram (ADR 0024; spec 2026-09-29 §5.2). Recorrente, a cada
# minuto, em cada cidade (EachCityJob). FOR UPDATE SKIP LOCKED: duas execuções
# concorrentes não pegam a mesma linha, e o PostgreSQL reavalia o
# status = 'scheduled' depois do lock — quem cancelou ou desagendou antes
# vence. O DispatchJob também é idempotente (só age em sending).
module Campaigns
  class DueJob < ApplicationJob
    prepend EachCityJob
    queue_as :default

    # Recuperação de sending preso: o DispatchJob entra na fila depois do commit;
    # se o processo cai no meio, ou ele esgota as tentativas, a campanha ficaria
    # em sending para sempre (o trigger só deixa sending → sent/failed). updated_at
    # marca a entrada em sending: nenhum UPDATE acontece enquanto ela está lá.
    # Reenfileirar é seguro: o DispatchJob trava a linha e sai se não for sending.
    STALE_SENDING = 10.minutes
    STALE_MAX = 24.hours

    def perform
      ApplicationRecord.transaction do
        due = Campaign.where(status: "scheduled").where(send_at: ..Time.current)
                      .order(:send_at, :id).lock("FOR UPDATE SKIP LOCKED").to_a
        due.each do |campaign|
          campaign.update!(status: "sending")
          DispatchJob.perform_later(city_slug: Current.city.slug, campaign_id: campaign.id)
        end
        requeue_stale_sending
      end
    end

    private

    def requeue_stale_sending
      Campaign.where(status: "sending", updated_at: (Time.current - STALE_MAX)..(Time.current - STALE_SENDING))
              .pluck(:id).each do |id|
        DispatchJob.perform_later(city_slug: Current.city.slug, campaign_id: id)
      end
    end
  end
end
