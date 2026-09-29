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

    # SMS encalhado: o SmsBatchJob entra na fila depois do commit do dispatch e
    # se reagenda sozinho (resto do lote, 8h do dia seguinte); se um desses se
    # perde, as linhas ficam pending/deferred sem ninguém. Parado = pending há
    # mais de STALE_PENDING (created_at: a linha nasce pending no congelamento e
    # nenhuma coluna marca a última tentativa), ou deferred dentro da janela.
    # Reenfileirar é seguro: o lote pega as linhas com SKIP LOCKED e só um lote
    # por campanha roda de cada vez (chain_lock); o que já saiu não volta a
    # pending/deferred. Teto de STALE_SMS_MAX: um lote que sempre levanta fora
    # do attempt (telefone que não decifra, CityPublicUrl mal configurado)
    # desfaz a transação e deixa as linhas como estavam; sem teto, ele voltaria
    # a cada minuto para sempre.
    #
    # Ruído de fila aceito: numa campanha grande, cujo lote legítimo passa de
    # 10 min, cada minuto enfileira um lote a mais. Com worker em série ele roda
    # entre dois lotes da cadeia, pega a trava e vira a cadeia; o próximo da
    # cadeia velha sai. Pode sobrar uma cadeia a mais por minuto na fila, nunca
    # SMS em dobro (SKIP LOCKED e chain_lock).
    STALE_PENDING = 10.minutes
    STALE_SMS_MAX = 48.hours

    def perform
      ApplicationRecord.transaction do
        due = Campaign.where(status: "scheduled").where(send_at: ..Time.current)
                      .order(:send_at, :id).lock("FOR UPDATE SKIP LOCKED").to_a
        due.each do |campaign|
          campaign.update!(status: "sending")
          DispatchJob.perform_later(city_slug: Current.city.slug, campaign_id: campaign.id)
        end
        requeue_stale_sending
        requeue_stuck_sms
      end
    end

    private

    def requeue_stale_sending
      Campaign.where(status: "sending", updated_at: (Time.current - STALE_MAX)..(Time.current - STALE_SENDING))
              .pluck(:id).each do |id|
        DispatchJob.perform_later(city_slug: Current.city.slug, campaign_id: id)
      end
    end

    def requeue_stuck_sms
      now = Time.current
      stuck = CampaignRecipient.where(sms_status: "pending", created_at: (now - STALE_SMS_MAX)...(now - STALE_PENDING))
      if SmsBatchJob::WINDOW_HOURS.cover?(now.hour)
        stuck = stuck.or(CampaignRecipient.where(sms_status: "deferred", created_at: (now - STALE_SMS_MAX)..))
      end
      Campaign.where(status: "sent", sms_enabled: true)
              .where(stuck.where("campaign_recipients.campaign_id = campaigns.id").arel.exists)
              .pluck(:id).each do |id|
        SmsBatchJob.perform_later(city_slug: Current.city.slug, campaign_id: id)
      end
    end
  end
end
