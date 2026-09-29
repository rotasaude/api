# app/jobs/campaigns/dispatch_job.rb
# Congelamento do público (ADR 0024, D7; spec 2026-09-29 §5.3). Numa
# transação: FOR UPDATE na campanha (fora de sending, sai — idempotente); lê a
# chave de SMS da cidade NESTE instante; insere as linhas num savepoint e
# conta os telefones DAS LINHAS (desvio 8) — abaixo de 5, desfaz e marca
# failed. O estado do SMS de cada linha sai do próprio INSERT:
#   chave desligada ou sem opt-in → not_opted_in;
#   com opt-in, menor citizen_id com opt-in daquele telefone → pending;
#   demais com opt-in do mesmo telefone → duplicate_phone.
# O aviso aparece no wpda assim que a transação comita; o lote de SMS entra na
# fila depois do commit (enqueue_after_transaction_commit).
module Campaigns
  class DispatchJob < ApplicationJob
    include CityScopedJob
    queue_as :default

    def perform(city_slug:, campaign_id:)
      with_city(city_slug) do
        campaign = Campaign.lock.find_by(id: campaign_id)
        next unless campaign&.status == "sending"

        sms_enabled = SmsSetting.enabled?
        counts = freeze_recipients(campaign, sms_enabled)
        next fail_below_minimum(campaign) unless counts

        campaign.update!(status: "sent", sms_enabled: sms_enabled, recipients_count: counts[:recipients],
                         phones_count: counts[:phones], dispatched_at: Time.current)
        DomainEvents.publish("campaign.dispatched", campaign_id: campaign.id, recipients_count: counts[:recipients],
                                                    phones_count: counts[:phones], sms_enabled: sms_enabled,
                                                    dispatched_by_user_id: campaign.dispatched_by_user_id,
                                                    audience: campaign.audience)
        if campaign.recipients.where(sms_status: "pending").exists?
          SmsBatchJob.perform_later(city_slug: city_slug, campaign_id: campaign.id)
        end
      end
    end

    private

    def freeze_recipients(campaign, sms_enabled)
      counts = nil
      ApplicationRecord.transaction(requires_new: true) do
        ApplicationRecord.connection.execute(insert_sql(campaign, sms_enabled))
        rows = CampaignRecipient.where(campaign_id: campaign.id).joins(:citizen)
        counts = { recipients: rows.count, phones: rows.distinct.count("citizens.phone") }
        raise ActiveRecord::Rollback if counts[:phones] < Campaign::MINIMUM_PHONES
      end
      counts if counts && counts[:phones] >= Campaign::MINIMUM_PHONES
    end

    def insert_sql(campaign, sms_enabled)
      connection = ApplicationRecord.connection
      <<~SQL
        INSERT INTO campaign_recipients (id, campaign_id, citizen_id, sms_status, created_at)
        SELECT gen_random_uuid(), #{connection.quote(campaign.id)}, c.id,
               CASE
                 WHEN NOT #{sms_enabled ? 'TRUE' : 'FALSE'} OR NOT COALESCE(p.sms_opt_in, FALSE) THEN 'not_opted_in'
                 WHEN row_number() OVER (PARTITION BY c.phone, COALESCE(p.sms_opt_in, FALSE) ORDER BY c.id) = 1
                   THEN 'pending'
                 ELSE 'duplicate_phone'
               END,
               #{connection.quote(Time.current)}
        FROM citizens c
        LEFT JOIN citizen_contact_preferences p ON p.citizen_id = c.id
        WHERE c.id IN (#{Audience.new(campaign.audience).citizen_ids.to_sql})
      SQL
    end

    def fail_below_minimum(campaign)
      campaign.update!(status: "failed", failure_reason: "below_minimum")
      DomainEvents.publish("campaign.failed", campaign_id: campaign.id, reason: "below_minimum",
                                              dispatched_by_user_id: campaign.dispatched_by_user_id)
    end
  end
end
