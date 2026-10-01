# Retenção dos dados do canal web do cidadão (api#31). Apaga linhas inteiras,
# uma delete_all por tabela, em cada cidade. Runbook: docs/operacao/
# atender-requisicao-lgpd.md (seção Retenção). O raw da mensagem recebida segue
# sendo zerado aos 90 dias por PurgeInboundRawJob (F-07.5); aqui sai a linha toda.
#
# Os prazos não devem encurtar — cada um tem um consumidor:
#   - otp_challenges: 7 dias depois de expirar. O limite diário de OTP conta os
#     desafios das últimas 24 h (OtpChallenge::DAILY_LIMIT).
#   - citizen_sessions: 30 dias depois de expirar OU de revogar (a sessão
#     desliza 30 dias).
#   - outbound_messages: 90 dias de criação; o conteúdo vive em
#     template/context/response.
#   - inbound_messages: 12 meses de criação; o painel Ingestão lê até 30 dias e
#     a deduplicação de reentrega da Meta usa message_id por ~7 dias.
class PurgeCitizenChannelJob < ApplicationJob
  prepend EachCityJob
  queue_as :housekeeping

  OTP_AFTER_EXPIRY = 7.days
  SESSION_AFTER_END = 30.days
  OUTBOUND_RETENTION = 90.days
  INBOUND_RETENTION = 12.months

  def perform
    now = Time.current

    otp = OtpChallenge.where("expires_at < ?", now - OTP_AFTER_EXPIRY).delete_all
    session_cutoff = now - SESSION_AFTER_END
    sessions = CitizenSession.where("expires_at < ? OR revoked_at < ?", session_cutoff, session_cutoff).delete_all
    outbound = OutboundMessage.where("created_at < ?", now - OUTBOUND_RETENTION).delete_all
    inbound = InboundMessage.where("created_at < ?", now - INBOUND_RETENTION).delete_all

    # Só contagens: nada de id nem telefone no log.
    Rails.logger.info("[purge_citizen_channel] otp_challenges=#{otp} citizen_sessions=#{sessions} " \
                      "outbound_messages=#{outbound} inbound_messages=#{inbound}")
  end
end
