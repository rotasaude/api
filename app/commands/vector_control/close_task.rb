# Fecha a tarefa da coordenação de endemias (módulo 35a, ADR 0054; contrato
# §6, §8, §17; Q9; A-14). Só a coordenação (endemic_coordinator; senão
# missing_role). Recusas (só a primeira):
#   - state fora de done | dismissed → invalid_request path state;
#   - nota ausente ou fora de 10–500 depois do strip → invalid_request path
#     note (Q9);
#   - sob `lock!`, tarefa que não está aberta → invalid_transition path status
#     (409; Q9). Uma vez só: o trigger recusa a segunda, e a regra compara o
#     estado, nunca o texto cifrado.
# Grava o estado, quem fechou e a nota (cifrada com a chave da cidade),
# version + 1; `vector_task.closed` só com ids. A nota nunca sai em log,
# evento, erro nem JSON.
module VectorControl
  module CloseTask
    STATES = %w[done dismissed].freeze
    EVENT = "vector_task.closed".freeze

    module_function

    # -> Result.ok(task:) | fail(:missing_role | :invalid_request | :invalid_transition, details: { path: })
    def call(task:, state:, note:, by:)
      return Result.fail(:missing_role) unless Access.coordinator?(by)
      return Result.fail(:invalid_request, details: { path: "state" }) unless STATES.include?(state)

      clean = note.is_a?(String) ? note.strip : nil
      return Result.fail(:invalid_request, details: { path: "note" }) unless clean && Catalog::NOTE.cover?(clean.length)

      VectorTask.transaction(requires_new: true) do
        task.lock!
        next Result.fail(:invalid_transition, details: { path: "status" }) unless task.state == "open"

        task.update!(state: state, closed_by_user: by, closed_note: clean, version: task.version + 1)
        DomainEvents.publish(EVENT, vector_task_id: task.id, user_id: by.id)
        Result.ok(task: task)
      end
    end
  end
end
