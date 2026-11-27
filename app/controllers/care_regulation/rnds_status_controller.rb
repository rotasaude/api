# GET /regulation/rnds/status (módulo 26c, Task 14; contrato §5, Q10, Q11): as
# contagens e a faixa do envio da regulação à RNDS. municipal_admin ou
# care_regulator; exige o interruptor LIGADO (`enabled?`), utilizável ou não:
# com a credencial recusada a tela abre e `usable`/`missing` dizem o motivo.
module CareRegulation
  class RndsStatusController < BaseController
    include ::RegulationRndsGate

    before_action { forbid unless admin? || regulator? }
    before_action :require_rnds_regulation_enabled!

    def show
      return unless query_only!

      missing = Platform::Features.missing(Current.city, Regulation::RndsGate::KEY)
      counts = Regulation::RndsAlert.counts(RegulationRndsSync.all, now: Time.current)
      pending = RegulationRndsSync.where(initial_load: true).where.not(status: "idle").count
      render json: Regulation::RndsJson.status(usable: missing.empty?, missing: missing, counts: counts, initial_load_pending: pending)
    end
  end
end
