# Condição de saúde declarada pelo cidadão (ADR 0040; contrato §7). Nunca
# é diagnóstico. Repetir a mesma não grava de novo; "none" retira as
# outras; uma condição retira o "none". Só acréscimo (retirar grava
# withdrawn_at). Eventos só com ids (citizen_id é a chave que o consumidor
# exige); o consumidor sugere a linha.
module CareLines
  module DeclareCondition
    module_function

    def call(citizen:, condition:)
      return Result.fail(:invalid_condition) unless Catalog::CONDITIONS.include?(condition)

      ApplicationRecord.transaction do
        citizen.lock!
        current = CitizenDeclaredCondition.current.where(citizen_id: citizen.id).to_a
        next Result.ok(condition: current.find { |c| c.condition == condition }) if current.any? { |c| c.condition == condition }

        stale = condition == "none" ? current : current.select { |c| c.condition == "none" }
        stale.each { |row| WithdrawCondition.withdraw!(row) }
        row = CitizenDeclaredCondition.create!(citizen: citizen, condition: condition, declared_at: Time.current)
        DomainEvents.publish("citizen_condition.declared", citizen_declared_condition_id: row.id, citizen_id: citizen.id)
        Result.ok(condition: row)
      end
    end
  end
end
