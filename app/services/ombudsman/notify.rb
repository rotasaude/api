# Aviso ao cidadão da ouvidoria (ADR 0051; contrato §9; Q15). Chamado DENTRO da
# transação do comando, depois da trava da manifestação (o cidadão já está em
# FOR KEY SHARE, como no Transport::Notify) e como a ÚLTIMA escrita do comando
# (F-24): o SMS sai dentro da transação e nada que falhe depois dele pode
# desfazer o aviso sem desfazer o SMS.
#
# O aviso não tem texto: só o tipo e a manifestação (o protocolo vem dela na
# caixa). O SMS é o texto fixo Catalog::SMS_TEXT, sem protocolo, só com a chave
# de SMS da cidade, o provedor, opt-in, sem `notices_muted` (o
# `appointment_reminders_muted` não vale aqui, A17) e dentro da janela 8h–20h
# do fuso da cidade; fora dela não envia nem reagenda. Falha do provedor só
# com a classe no log: o aviso fica.
module Ombudsman
  module Notify
    module_function

    # -> true quando o aviso nasceu; false quando a manifestação não tem cidadão.
    def call(manifestation:, kind:, now: Time.current)
      kind = kind.to_s
      raise ArgumentError, "kind" unless Catalog::NOTICE_KINDS.include?(kind)
      return false unless manifestation.citizen_id

      OmbudsmanNotice.create!(citizen_id: manifestation.citizen_id, ombudsman_manifestation_id: manifestation.id,
                              kind: kind, created_at: now)
      deliver(manifestation.citizen_id, now)
      true
    end

    def deliver(citizen_id, now)
      return unless Campaigns::SmsSetting.enabled? && SmsGateway.configured?
      return unless Campaigns::SmsBatchJob::WINDOW_HOURS.cover?(now.in_time_zone.hour)

      preference = CitizenContactPreference.find_by(citizen_id: citizen_id)
      return unless preference&.sms_opt_in && !preference.notices_muted

      SmsGateway.deliver(phone: Citizen.find(citizen_id).phone, body: Catalog::SMS_TEXT)
    rescue ActiveRecord::ActiveRecordError
      raise
    rescue StandardError => e
      Rails.logger.warn("[ombudsman.notice] SMS não saiu: #{e.class}")
    end

    private_class_method :deliver
  end
end
