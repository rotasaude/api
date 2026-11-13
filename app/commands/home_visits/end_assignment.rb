# Encerra a atribuição de microárea (módulo 24b, ADR 0052; contrato §2, §6;
# Q21). Final: encerrada → 409 assignment_already_ended; reatribuir cria linha
# nova. A linha travada decide a corrida de dois encerramentos. O escopo do
# profissional muda na hora (HomeVisits::Access.scope relê a tabela) e o
# próximo download do app responde reset (§9.3; Q9). Quem chama já conferiu o
# enfermeiro da equipe e o step-up. Evento só com ids.
module HomeVisits
  module EndAssignment
    module_function

    def call(assignment:, by:)
      MicroAreaFieldAssignment.transaction(requires_new: true) do
        assignment.lock!
        next Result.fail(:assignment_already_ended) unless assignment.active?

        assignment.update!(ended_at: Time.current, ended_by_user: by)
        DomainEvents.publish("micro_area.field_assignment_changed", micro_area_id: assignment.micro_area_id,
                                                                   professional_id: assignment.professional_id, user_id: by.id, ended: true)
        Result.ok(assignment: assignment)
      end
    end
  end
end
