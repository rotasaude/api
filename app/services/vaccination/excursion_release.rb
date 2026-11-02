# Soltura dos bloqueios da excursão de temperatura (ADR 0047; Task 14).
#
# - `discard!`: o bloqueio cai com `decision: "discard"` quando a perda do
#   lote foi APLICADA (na hora, abaixo do limite do 27a, ou na aprovação) — ou
#   quando não havia saldo a dar perda —, e os frascos ainda abertos do lote na
#   sala do local fecham como descartados (autor e motivo da conduta; a sobra
#   vira perda técnica, como no CloseOutVial).
# - `adjustment_applied!`: chamado pelo Pharmacy::DecideAdjustment ao aprovar;
#   solta os bloqueios ligados ao ajuste. Sem bloqueio ligado, nada faz.
# - `close_if_settled!`: a excursão fecha (decided_at, decided_by) quando não
#   resta bloqueio aberto dela; o autor é quem decidiu a conduta (ou quem leu,
#   na excursão sem lotes).
#
# Corre dentro da transação de quem chama, depois das travas de lote e local.
# Na aprovação (adjustment_applied!) a ordem real é lote → local → ajuste →
# frascos → excursão; no DecideExcursion, lotes → local → excursão → ajuste →
# frascos. Os dois começam pelo lote e por isso se serializam nele.
module Vaccination
  module ExcursionRelease
    module_function

    def adjustment_applied!(adjustment:, now:)
      blocks = StockLotBlock.open_blocks.where(stock_adjustment_id: adjustment.id).order(:id).to_a
      blocks.each { |block| discard!(block, now: now) }
      blocks.map { |block| [ block.cold_chain_excursion_id, block.decided_by_user_id ] }.uniq.each do |excursion_id, by_id|
        close_if_settled!(excursion_id, by_id: by_id, now: now)
      end
    end

    def discard!(block, now:)
      block.update!(released_at: now, decision: "discard")
      room = VaccineRoom.find_by(stock_location_id: block.stock_location_id)
      return unless room

      VialOpening.open_vials.where(vaccine_room_id: room.id, stock_lot_id: block.stock_lot_id).order(:id).lock("FOR UPDATE").each do |vial|
        vial.update!(closed_at: now, closed_by_user_id: block.decided_by_user_id, close_reason: block.decision_reason,
                     technical_loss_doses: vial.doses_left)
        DomainEvents.publish("vaccination.vial_closed", vial_opening_id: vial.id, vaccine_room_id: room.id,
                                                        user_id: block.decided_by_user_id, cause: "closed_out")
      end
    end

    # `outcome`: "decided" (todos os lotes com conduta aplicada) ou "no_lots"
    # (fechada na leitura: nada a bloquear). -> true quando fechou agora
    def close_if_settled!(excursion_id, by_id:, now:, outcome: "decided")
      excursion = ColdChainExcursion.lock("FOR UPDATE").find(excursion_id)
      return false if excursion.decided_at
      return false if StockLotBlock.open_blocks.exists?(cold_chain_excursion_id: excursion.id)

      excursion.update!(decided_at: now, decided_by_user_id: by_id)
      DomainEvents.publish("vaccination.cold_chain_excursion_decided", cold_chain_excursion_id: excursion.id,
                                                                       stock_location_id: excursion.stock_location_id, user_id: by_id,
                                                                       outcome: outcome)
      true
    end
  end
end
