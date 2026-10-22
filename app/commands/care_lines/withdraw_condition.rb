# Retira uma condição declarada vigente (contrato §7, §11 T1). Fora do
# domínio → invalid_condition; não vigente → not_found.
module CareLines
  module WithdrawCondition
    module_function

    def call(citizen:, condition:)
      return Result.fail(:invalid_condition) unless Catalog::CONDITIONS.include?(condition)

      ApplicationRecord.transaction do
        citizen.lock!
        row = CitizenDeclaredCondition.current.where(citizen_id: citizen.id).to_a.find { |c| c.condition == condition }
        next Result.fail(:not_found) unless row

        withdraw!(row)
        Result.ok(condition: row)
      end
    end

    def withdraw!(row)
      row.update!(withdrawn_at: Time.current)
      DomainEvents.publish("citizen_condition.withdrawn", citizen_declared_condition_id: row.id, citizen_id: row.citizen_id)
    end
  end
end
