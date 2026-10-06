# Alerta do console (ADR 0028; spec 2026-10-05 §4): a partir do dia 5, sem a
# SIGTAP da competência corrente ativa. `GET /city_production` (plano do
# exportador) publica sigtap_current_competence e sigtap_imported.
module Terminology
  module SigtapStatus
    ALERT_DAY = 5

    def self.call(today: Time.zone.today)
      competence = today.strftime("%Y%m")
      imported = TerminologyRelease.active.exists?(kind: "sigtap", version: competence)
      { sigtap_current_competence: competence, sigtap_imported: imported, alert: !imported && today.day >= ALERT_DAY }
    end
  end
end
