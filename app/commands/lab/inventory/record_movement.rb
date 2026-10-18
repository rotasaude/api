# Saída e acerto (spec §6.3–§6.5; contrato §5): abertura, perda e
# vencimento recebem quantidade positiva e gravam negativa; ajuste (só
# admin) aceita sinal; perda, vencimento e ajuste exigem motivo (até 1000,
# C-E11); quantidade 1..100000 em valor absoluto. Saldo = soma dos
# movimentos, conferido com o lote travado (FOR UPDATE) — duas saídas do
# último kit ao mesmo tempo: uma passa, a outra leva insufficient_balance.
# O trigger do saldo é o cinto: se a conta da aplicação falhar, ele recusa.
module Lab
  module Inventory
    module RecordMovement
      KINDS = %w[opening loss expiry adjustment].freeze
      REASON_MAX = 1000
      NEGATIVE_BALANCE = /negative balance refused/

      module_function

      def call(lot:, kind:, quantity:, reason:, by:, admin:, now: Time.current)
        return Result.fail(:invalid_kind) unless KINDS.include?(kind)
        return Result.fail(:missing_role) if kind == "adjustment" && !admin

        valid = quantity.is_a?(Integer) && quantity.abs.between?(1, 100_000) && (kind == "adjustment" || quantity.positive?)
        return Result.fail(:invalid_quantity) unless valid

        text = reason.is_a?(String) ? reason.strip.presence : nil
        return Result.fail(:reason_required) if kind != "opening" && text.nil?
        return Result.fail(:invalid_reason) if text && text.length > REASON_MAX

        signed = kind == "adjustment" ? quantity : -quantity
        ApplicationRecord.transaction(requires_new: true) do
          lot.lock!
          balance = lot.balance
          next Result.fail(:insufficient_balance) if balance + signed < 0

          movement = LabSupplyMovement.create!(lab_supply_lot: lot, kind: kind, quantity: signed, reason: text, recorded_by_user: by,
                                               recorded_at: now, created_at: now)
          DomainEvents.publish(
            "lab_supply_movement.recorded",
            lab_supply_movement_id: movement.id, kind: kind
          )
          Result.ok(movement: movement, balance: balance + signed)
        end
      rescue ActiveRecord::StatementInvalid => e
        raise unless e.message.match?(NEGATIVE_BALANCE)

        Result.fail(:insufficient_balance)
      end
    end
  end
end
