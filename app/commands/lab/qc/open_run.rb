# Corrida aberta a pedido (spec §5.2): sempre nova; vira a "do dia" (a mais recente não reprovada).
module Lab
  module Qc
    module OpenRun
      module_function

      def call(instrument:, by:, now: Time.current)
        ApplicationRecord.transaction(requires_new: true) do
          instrument.lock!
          Result.ok(run: LabQcRun.create!(lab_instrument: instrument, sector: instrument.sector, status: "open", started_at: now, opened_by_user: by))
        end
      end
    end
  end
end
