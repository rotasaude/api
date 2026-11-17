# Peças comuns dos comandos do bloqueio de transmissão (módulo 35a, ADR 0054;
# contrato §8; Q9). Toda escrita do bloqueio toma primeiro a mesma trava
# consultiva da proposta (Propose: serializa o agrupamento contra a
# confirmação, o descarte, o fechamento, o ciclo e o mover) e só depois as
# linhas, sempre nessa ordem. Recusas só com `path`: nunca valor do caso.
module VectorControl
  module Blocks
    module Support
      UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
      OPEN = %w[proposed active].freeze
      LOCK = "SELECT pg_advisory_xact_lock(hashtextextended('vector_control:transmission_blocks', 0))".freeze

      module_function

      def serialize! = ApplicationRecord.connection.execute(LOCK)

      def uuid?(value) = value.is_a?(String) && value.match?(UUID)

      def invalid(path) = Result.fail(:invalid_request, details: { path: path })

      # Q9: transição fora do estado.
      def transition = Result.fail(:invalid_transition, details: { path: "status" })
    end
  end
end
