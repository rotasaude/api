# Controle pela HL7 (spec §7; contrato §6; Task 0): dentro da transação da
# mensagem e ANTES das amostras de paciente (Desvio 10: aparelho primeiro).
# SPM-2 = código de barras de nível de lote cadastrado do laboratório do
# token → controle (claimed: o caminho do paciente pula esse SPM). SPM-11 = Q
# com código que não é de controle → unknown_barcode (claimed também: nunca
# vira paciente). Confere tudo antes de gravar (B26); os valores de um
# aparelho na mensagem ficam na mesma corrida (Desvio 6).
module Lab
  module Qc
    class Hl7Inbound
      FAILURES = { lot_closed: "qc_lot_closed", expired_lot: "qc_lot_expired", no_target: "qc_no_target",
                   invalid_instrument: "unknown_instrument" }.freeze

      attr_reader :claimed

      def initialize(message, token, receipt, now, enabled:, write:)
        @message = message
        @token = token
        @receipt = receipt
        @now = now
        @enabled = enabled
        @write = write
        @claimed = Set.new
        @errors = []
      end

      def run
        plan = @message.specimens.flat_map { |specimen| plan_for(specimen) }
        return @errors if @errors.any? || !@write || plan.empty?

        LabInstrument.where(id: plan.map { |step| step[:instrument].id }.uniq).order(:id).lock.to_a
        runs = {}
        plan.each do |step|
          recorded = RecordValue.call(instrument: step[:instrument], lot: step[:lot], level: step[:level], analyte_key: step[:analyte_key],
                                      value: step[:value], source: "hl7", receipt: @receipt, run: runs[step[:instrument].id], now: @now)
          if recorded.failure?
            @errors << error(FAILURES.fetch(recorded.reason, "invalid_value"), step[:where])
          else
            runs[step[:instrument].id] ||= recorded.payload[:run]
          end
        end
        @errors
      end

      private

      def error(code, location) = Lab::Hl7::Builder::Error.new(code: code, location: location)

      def plan_for(specimen)
        where = "SPM^#{specimen.index}^2"
        entry = LabQcLotBarcode.joins(lab_qc_lot: :lab_qc_material).where(lab_qc_materials: { exam_provider_id: @token.exam_provider_id })
                               .includes(lab_qc_lot: :lab_qc_material)
                               .merge(LabQcLotBarcode.matching(@message.barcode(specimen))).first # C-E13: sem caixa
        unless entry
          if @message.specimen_role(specimen) == "Q"
            @claimed << specimen.index
            @errors << error("unknown_barcode", where)
          end
          return []
        end

        @claimed << specimen.index
        lot = entry.lab_qc_lot
        refusal = if !@enabled then "qc_disabled"
                  elsif lot.status == "closed" then "qc_lot_closed"
                  elsif lot.expired?(@now.in_time_zone.to_date) then "qc_lot_expired"
                  end
        if refusal
          @errors << error(refusal, where)
          return []
        end
        specimen.orders.flat_map { |order| order_plan(order, lot, entry.level) }
      end

      def order_plan(order, lot, level)
        material = lot.lab_qc_material
        code = @message.field(order.obr, 4, 1).to_s
        exam = exam_for(material, code)
        unless exam
          @errors << error("exam_not_in_version", "OBR^#{order.index}^4") if code.present? # vazio: já é erro de forma
          return []
        end

        seen = Set.new
        steps = []
        order.results.each do |obx|
          step = obx_step(obx, exam, material, lot, level, seen)
          steps << step if step
        end
        steps
      end

      def obx_step(obx, exam, material, lot, level, seen)
        segment = obx.segment
        at = ->(field) { "OBX^#{obx.index}^#{field}" }
        key = @message.field(segment, 3, 1).to_s
        return nil if key.blank? # forma: structure_errors

        analyte = exam.current_version.analyte(key)
        unless analyte && material.analyte_entry(key, exam_id: exam.id)
          @errors << error("unknown_analyte", at.call(3))
          return nil
        end
        unit = @message.field(segment, 6, 1).to_s
        if unit.present? && analyte["unit"].present? && unit != analyte["unit"]
          @errors << error("unit_mismatch", at.call(6))
          return nil
        end
        value = Decimal.hl7(@message.field(segment, 5, 1).to_s)
        unless value
          @errors << error("invalid_value", at.call(5))
          return nil
        end
        instrument = instrument_for(@message.repetitions(segment, 18))
        unless instrument
          @errors << error("unknown_instrument", at.call(18))
          return nil
        end
        unless LabQcTarget.current(lot_id: lot.id, level: level, analyte_key: key, instrument_id: instrument.id)
          @errors << error("qc_no_target", at.call(3))
          return nil
        end
        # Dois OBX do mesmo analito no mesmo OBR: a ordem não decide qual vale (como E5/B26).
        unless seen.add?(key)
          @errors << error("invalid_value", at.call(5))
          return nil
        end
        { instrument: instrument, lot: lot, level: level, analyte_key: key, value: value, where: at.call(5) }
      end

      def exam_for(material, code)
        return nil if code.blank?

        LabExam.where(id: material.analytes.map { |a| a["lab_exam_id"] }, exam_provider_id: @token.exam_provider_id, active: true)
               .joins(:current_version).includes(:current_version)
               .find_by("upper(lab_exam_versions.instrument_test_code) = ?", code.upcase)
      end

      # A repetição de OBX-18 que casa com UM aparelho ativo do laboratório (sem diferenciar caixa).
      def instrument_for(ids)
        return nil if ids.empty?

        found = LabInstrument.active.where(exam_provider_id: @token.exam_provider_id)
                             .where("upper(hl7_equipment_id) IN (?)", ids.map(&:upcase)).to_a
        found.size == 1 ? found.first : nil
      end
    end
  end
end
