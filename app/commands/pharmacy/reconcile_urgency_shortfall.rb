# Conciliação de uma falta de estoque da UPA (ADR 0050; contrato §7 e §12 Q7;
# plano, Desvio 12): a farmácia confere por fora (reposição, ajuste, ressarcimento)
# e registra a nota. NÃO grava movimento de estoque. A nota (10 a 500
# caracteres) é cifrada com a chave da cidade e nunca sai em log, evento nem erro.
#
# Quem concilia: farmacêutico ou almoxarife do local da falta, ou o almoxarife
# do central (`missing_role`, 403); a falta `no_location` só o almoxarife do
# central. A recusa de papel vem sozinha, antes da nota. Sob `lock!`, uma falta
# já conciliada → `already_reconciled` (409). Evento só com o id.
module Pharmacy
  module ReconcileUrgencyShortfall
    ROLES = %w[pharmacist stock_keeper].freeze

    module_function

    # Papel de quem pode ler/conciliar a falta (também usado pela lista).
    def allowed?(user:, location:)
      return Access.central_keeper?(user) if location.nil?

      Access.allowed?(user: user, location: location, roles: ROLES) || Access.central_keeper?(user)
    end

    # -> Result.ok(shortfall:) | fail(:missing_role) | fail(:invalid_request, path: "note") |
    # fail(:already_reconciled)
    def call(shortfall:, note:, by:, now: Time.current)
      return Result.fail(:missing_role) unless allowed?(user: by, location: shortfall.stock_location)

      clean = note.is_a?(String) ? note.strip : nil
      unless clean && Urgency::Catalog::RECONCILIATION_NOTE.cover?(clean.length)
        return Result.fail(:invalid_request, details: { path: "note", problems: [ { path: "note", error: "invalid_request" } ] })
      end

      result = nil
      UrgencyStockShortfall.transaction(requires_new: true) do
        shortfall.lock!
        if shortfall.reconciled_at
          result = Result.fail(:already_reconciled)
        else
          shortfall.update!(reconciled_at: now, reconciled_by_user: by, reconciliation_note: clean)
          DomainEvents.publish("pharmacy.urgency_shortfall_reconciled", shortfall_id: shortfall.id)
          result = Result.ok(shortfall: shortfall)
        end
      end
      result
    end
  end
end
