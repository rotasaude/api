# app/jobs/campaigns/sms_batch_job.rb
# Entrega do SMS de uma campanha já enviada (ADR 0024; spec 2026-09-29 §5.4).
# Recebe só ids (nunca telefone): decifra dentro. Até BATCH_SIZE linhas
# pending/deferred por vez, travadas com SKIP LOCKED (dois lotes não pegam a
# mesma linha). Gateway não configurado → unavailable na hora (desvio 9), e o
# provedor que cai no meio do lote também marca unavailable; nos dois casos
# campaign.sms_unavailable sai uma vez por campanha. Fora da janela 8h–20h no
# fuso da cidade → deferred e reagenda para as 8h. O opt-in é conferido de
# novo aqui. A falha de um destinatário nunca interrompe
# o lote; sms_error guarda só a classe do erro (a mensagem pode ter telefone).
module Campaigns
  class SmsBatchJob < ApplicationJob
    include CityScopedJob
    queue_as :default

    BATCH_SIZE = 100
    WINDOW_HOURS = (8...20)
    ATTEMPTS = 2
    OPEN = %w[pending deferred].freeze

    def perform(city_slug:, campaign_id:)
      with_city(city_slug) do
        campaign = Campaign.find_by(id: campaign_id)
        next unless campaign&.status == "sent"

        batch = campaign.recipients.where(sms_status: OPEN).order(:id).limit(BATCH_SIZE)
                        .lock("FOR UPDATE SKIP LOCKED").includes(:citizen).to_a
        next if batch.empty?
        next mark_unavailable(campaign) unless SmsGateway.configured?

        now = Time.current
        unless WINDOW_HOURS.cover?(now.hour)
          campaign.recipients.where(sms_status: "pending").update_all(sms_status: "deferred")
          self.class.set(wait_until: next_window_start(now)).perform_later(city_slug: city_slug, campaign_id: campaign.id)
          next
        end

        body = SmsText.body(Current.city)
        opted = CitizenContactPreference.where(citizen_id: batch.map(&:citizen_id), sms_opt_in: true)
                                        .pluck(:citizen_id).to_set
        statuses = batch.map { |recipient| deliver(recipient, body, opted) }
        publish_unavailable(campaign, statuses.count("unavailable"))
        if campaign.recipients.where(sms_status: OPEN).exists?
          self.class.perform_later(city_slug: city_slug, campaign_id: campaign.id)
        end
      end
    end

    private

    def mark_unavailable(campaign)
      publish_unavailable(campaign, campaign.recipients.where(sms_status: OPEN).update_all(sms_status: "unavailable"))
    end

    # Uma vez por campanha, venha do gateway não configurado ou do provedor que
    # cai no meio do lote: o count é o do primeiro lote que viu a falha (o
    # painel conta os unavailable ao vivo).
    def publish_unavailable(campaign, count)
      return unless count.positive?
      return if DomainEvent.where(name: "campaign.sms_unavailable")
                           .exists?([ "payload ->> 'campaign_id' = ?", campaign.id.to_s ])

      DomainEvents.publish("campaign.sms_unavailable", campaign_id: campaign.id, count: count)
    end

    # Grava e devolve o sms_status do destinatário.
    def deliver(recipient, body, opted)
      unless opted.include?(recipient.citizen_id)
        recipient.update!(sms_status: "not_opted_in")
        return "not_opted_in"
      end

      case (error = attempt(recipient.citizen.phone, body))
      when nil then recipient.update!(sms_status: "sent", sms_sent_at: Time.current, sms_error: nil)
      when SmsGateway::Unavailable then recipient.update!(sms_status: "unavailable")
      else recipient.update!(sms_status: "failed", sms_error: error.class.name.truncate(200))
      end
      recipient.sms_status
    end

    # Uma retentativa. Devolve nil (entregue) ou o erro da última tentativa.
    def attempt(phone, body)
      ATTEMPTS.times do |i|
        SmsGateway.deliver(phone: phone, body: body)
        return nil
      rescue SmsGateway::Unavailable => e
        return e
      rescue StandardError => e
        return e if i == ATTEMPTS - 1
      end
    end

    def next_window_start(now)
      start = now.change(hour: WINDOW_HOURS.first)
      now < start ? start : start + 1.day
    end
  end
end
