# Lote em uso (spec §6.3; contrato §5): só reagente, não vencido, de um
# exame ligado ao item e de aparelho ativo do mesmo laboratório. Trava só o
# APARELHO (ordem do Desvio 10; nunca o lote nem o item), encerra o lote
# corrente do par e abre o novo. O mesmo lote de novo (C-E6) devolve o
# registro corrente sem criar nada (`created: false`).
module Lab
  module Inventory
    module SetInUse
      module_function

      def call(lot_id:, instrument_id:, lab_exam_id:, by:, now: Time.current)
        lot = uuid?(lot_id) && LabSupplyLot.includes(:lab_supply).find_by(id: lot_id)
        return Result.fail(:not_found) unless lot

        supply = lot.lab_supply
        return Result.fail(:lot_not_reagent) unless supply.kind == "reagent"
        return Result.fail(:expired_lot) if lot.expired?(now.in_time_zone.to_date)

        instrument = uuid?(instrument_id) && LabInstrument.active.find_by(id: instrument_id, exam_provider_id: supply.exam_provider_id)
        return Result.fail(:invalid_instrument) unless instrument

        exam = uuid?(lab_exam_id) && LabExam.find_by(id: lab_exam_id, exam_provider_id: supply.exam_provider_id)
        return Result.fail(:exam_not_linked) unless exam && supply.lab_exam_ids.include?(exam.id)

        ApplicationRecord.transaction(requires_new: true) do
          instrument.lock!
          next Result.fail(:invalid_instrument) unless instrument.active

          current = LabSupplyInUse.current.find_by(lab_instrument_id: instrument.id, lab_exam_id: exam.id)
          next Result.ok(in_use: current, created: false) if current&.lab_supply_lot_id == lot.id

          current&.update!(ended_at: now, ended_by_user: by)
          created = LabSupplyInUse.create!(lab_supply_lot: lot, lab_instrument: instrument, lab_exam: exam, started_at: now, started_by_user: by)
          DomainEvents.publish(
            "lab_supply_in_use.changed",
            lab_supply_in_use_id: created.id, lab_instrument_id: instrument.id, lab_exam_id: exam.id
          )
          Result.ok(in_use: created, created: true)
        end
      end

      def uuid?(value) = value.is_a?(String) && value.match?(Exams::BaseController::UUID)
      private_class_method :uuid?
    end
  end
end
