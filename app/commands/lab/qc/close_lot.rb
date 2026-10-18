# Encerrar o lote de controle (contrato §3): só in_use → closed (trigger).
module Lab
  module Qc
    module CloseLot
      module_function

      def call(lot:, now: Time.current)
        ApplicationRecord.transaction(requires_new: true) do
          lot.lock!
          next Result.fail(:invalid_transition, details: { status: lot.status }) unless lot.status == "in_use"

          lot.update!(status: "closed", closed_on: now.in_time_zone.to_date)
          Result.ok(lot: lot)
        end
      end
    end
  end
end
