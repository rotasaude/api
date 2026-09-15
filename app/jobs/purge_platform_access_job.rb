# Purga diária do que expira na PLATAFORMA (Plano 4): grants de entrada vencidos há
# mais de RETENTION e sessões de operador que não autenticam mais — pendentes além
# de PENDING_MFA_WINDOW, verificadas além de OPERATOR_SESSION_TTL. A trilha de
# acesso fica em platform_events; estas linhas são só estado de curta duração.
class PurgePlatformAccessJob < ApplicationJob
  queue_as :housekeeping

  RETENTION = 1.day

  def perform
    now = Time.current
    CityGrant.where("expires_at < ?", now - RETENTION).delete_all
    OperatorSession.where(mfa_verified_at: nil)
                   .where("created_at < ?", now - OperatorAuthentication::PENDING_MFA_WINDOW).delete_all
    OperatorSession.where("mfa_verified_at < ?", now - OperatorAuthentication::OPERATOR_SESSION_TTL).delete_all
  end
end
