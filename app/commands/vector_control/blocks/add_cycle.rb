# Ciclo de UBV do bloqueio ativo (módulo 35a, ADR 0054; contrato §8, §11; Q9;
# W-8). Só a coordenação (quem chama confere). Recusas (só a primeira):
#   - starts_on/ends_on ausentes ou fora de "YYYY-MM-DD" → invalid_request
#     com o path;
#   - sob a trava e `lock!`, bloqueio fora de active → invalid_transition
#     path status (409; Q9);
#   - já com ubv_cycles_max ciclos (no máximo 3, o CHECK) → cycle_invalid
#     path cycles;
#   - duração inclusiva (ends_on − starts_on + 1) fora de
#     [ubv_cycle_days_min, ubv_cycle_days_max] → cycle_invalid path ends_on;
#   - starts_on < ends_on do anterior + ubv_cycle_interval_days →
#     cycle_invalid path starts_on (o "intervalo de 4 dias" do §19).
# O número é o próximo do bloqueio. Sem evento (§17).
module VectorControl
  module Blocks
    module AddCycle
      DATE = /\A\d{4}-\d{2}-\d{2}\z/

      module_function

      # -> Result.ok(block:, cycle:) | fail(:invalid_request | :invalid_transition | :cycle_invalid, details: { path: })
      def call(block:, starts_on:, ends_on:, by:)
        starts = date(starts_on)
        return Support.invalid("starts_on") unless starts

        ends = date(ends_on)
        return Support.invalid("ends_on") unless ends

        TransmissionBlock.transaction(requires_new: true) do
          Support.serialize!
          block.lock!
          next Support.transition unless block.status == "active"

          values = Parameters.current.values
          cycles = block.cycles.order(:number).to_a
          next invalid("cycles") if cycles.size >= [ values.fetch("ubv_cycles_max").to_i, Catalog::UBV_NUMBERS.max ].min

          days = (ends - starts).to_i + 1
          next invalid("ends_on") unless (values.fetch("ubv_cycle_days_min").to_i..values.fetch("ubv_cycle_days_max").to_i).cover?(days)

          last = cycles.last
          next invalid("starts_on") if last && starts < last.ends_on + values.fetch("ubv_cycle_interval_days").to_i

          cycle = block.cycles.create!(number: cycles.size + 1, starts_on: starts, ends_on: ends)
          Result.ok(block: block, cycle: cycle)
        end
      end

      def date(value)
        return nil unless value.is_a?(String) && value.match?(DATE)

        Date.iso8601(value)
      rescue Date::Error
        nil
      end

      def invalid(path) = Result.fail(:cycle_invalid, details: { path: path })
      private_class_method :date, :invalid
    end
  end
end
