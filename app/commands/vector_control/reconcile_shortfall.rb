# Conciliação de uma falta de insumo do boletim (módulo 35a, ADR 0054;
# contrato §4; Q9): quem confere por fora (reposição, ajuste) registra a nota.
# NÃO grava movimento de estoque (como o 32b). A nota (10 a 500 caracteres
# depois do strip) é cifrada com a chave da cidade e nunca sai em log, evento,
# erro nem JSON.
#
# Quem concilia: a coordenação (endemic_coordinator) ou o `stock_keeper` do
# local da falta (Pharmacy::Access, Membership ativa + vínculo ativo); a falta
# `no_location` só a coordenação (`missing_role`, 403, sozinha, antes da nota).
# Nota ausente ou fora de 10–500 → `invalid_request` path `note` (Q9). Sob
# `lock!`, falta já conciliada (pela pessoa ou pelo sistema, no estorno) →
# `already_reconciled` (409). Uma vez só: o trigger recusa a segunda, e a
# regra compara o estado (`reconciled_at`), nunca o texto cifrado. Evento
# `vector_stock.shortfall_reconciled` só com ids.
module VectorControl
  module ReconcileShortfall
    EVENT = "vector_stock.shortfall_reconciled".freeze

    module_function

    # Lê e concilia a falta: coordenação, ou o stock_keeper do local (nunca a no_location).
    def allowed?(user:, location:)
      return true if Access.coordinator?(user)

      !location.nil? && Pharmacy::Access.allowed?(user: user, location: location, roles: %w[stock_keeper])
    end

    # -> Result.ok(shortfall:) | fail(:missing_role) | fail(:invalid_request, details: { path: "note" }) |
    #    fail(:already_reconciled)
    def call(shortfall:, note:, by:, now: Time.current)
      return Result.fail(:missing_role) unless allowed?(user: by, location: shortfall.stock_location)

      clean = note.is_a?(String) ? note.strip : nil
      return Result.fail(:invalid_request, details: { path: "note" }) unless clean && Catalog::NOTE.cover?(clean.length)

      VectorStockShortfall.transaction(requires_new: true) do
        shortfall.lock!
        next Result.fail(:already_reconciled) if shortfall.reconciled_at

        shortfall.update!(reconciled_at: now, reconciled_by_user: by, reconciliation_note: clean, version: shortfall.version + 1)
        DomainEvents.publish(EVENT, vector_stock_shortfall_id: shortfall.id, user_id: by.id)
        Result.ok(shortfall: shortfall)
      end
    end
  end
end
