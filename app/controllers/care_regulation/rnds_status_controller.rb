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
      # Só o que ainda espera a vez na faixa da carga inicial (re-revisão N3):
      # a linha parada, recusada ou desistida da faixa não conta no aviso
      # ("N pedidos na fila, no ritmo de 60 por minuto"). O `initial_load` em
      # si fica como está: é a faixa e a carência do alarme (do enqueued_at, Q26).
      pending = RegulationRndsSync.where(initial_load: true, status: %w[queued sending]).count
      render json: Regulation::RndsJson.status(usable: missing.empty?, missing: missing, counts: counts, initial_load_pending: pending)
    end
  end
end
