# app/services/sncr/checks.rb
# Estado do SNCR para o maintenance (contrato §8): configurado no ambiente,
# alcançável pela última conversa REAL, e se o simulado existe aqui.
module Sncr
  module Checks
    module_function

    def record!(settings, ok:) = settings && SncrCheck.record!(settings.target, ok: ok)

    def status
      check = SncrCheck.last("real")
      { configured: Config.configured?, reachable: check&.last_check_ok || false, last_check_at: check&.last_check_at,
        simulated_available: Config.simulated_available? }
    end
  end
end
