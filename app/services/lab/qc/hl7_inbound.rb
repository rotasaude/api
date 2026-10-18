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
      SAMPLE_SPACE = LabQcLotBarcode::SAMPLE_SPACE

      attr_reader :claimed

      def initialize(message, token, receipt, now, enabled:, write:)
        @message = message
        @token = token
        @receipt = receipt
        @now = now
        @enabled = enabled
        @write = write
        @claimed = Set.new
        @seen = Set.new
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
        entry = control_barcode(@message.barcode(specimen))
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

      # C-E10: código de controle nunca tem só 10 dígitos (check do banco): amostra de
      # paciente (ou código vazio) nem consulta a tabela. C-E13: sem diferenciar caixa.
      def control_barcode(code)
        return nil if code.blank? || code.match?(SAMPLE_SPACE)

        LabQcLotBarcode.joins(lab_qc_lot: :lab_qc_material).where(lab_qc_materials: { exam_provider_id: @token.exam_provider_id })
                       .includes(lab_qc_lot: :lab_qc_material).merge(LabQcLotBarcode.matching(code)).first
      end

      def order_plan(order, lot, level)
        material = lot.lab_qc_material
        code = @message.field(order.obr, 4, 1).to_s
        exam = exam_for(material, code)
        unless exam
          @errors << error("exam_not_in_version", "OBR^#{order.index}^4") if code.present? # vazio: já é erro de forma
          return []
        end

        steps = []
        order.results.each do |obx|
          step = obx_step(obx, exam, material, lot, level)
          steps << step if step
        end
        steps
      end

      def obx_step(obx, exam, material, lot, level)
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
        # O mesmo lote, nível, analito e aparelho duas vezes NA MENSAGEM (outro OBX, OBR ou SPM):
        # a ordem não decide qual vale (como E5/B26 do paciente, que deduplica a mensagem inteira).
        unless @seen.add?([ lot.id, level, key, instrument.id ])
          @errors << error("invalid_value", at.call(5))
          return nil
        end
        { instrument: instrument, lot: lot, level: level, analyte_key: key, value: value, where: at.call(5) }
      end

      # Comparado em Ruby: nada da mensagem (OBR-4, OBX-18) vai ao texto do SQL nem ao log.
      def exam_for(material, code)
        return nil if code.blank?

        @exams ||= {}
        exams = @exams[material.id] ||= LabExam.where(id: material.analytes.map { |a| a["lab_exam_id"] }, exam_provider_id: @token.exam_provider_id,
                                                      active: true).joins(:current_version).includes(:current_version).to_a
        exams.find { |exam| exam.current_version.instrument_test_code.to_s.casecmp?(code) }
      end

      # A repetição de OBX-18 que casa com UM aparelho ativo do laboratório (sem diferenciar caixa).
      def instrument_for(ids)
        return nil if ids.empty?

        @instruments ||= LabInstrument.active.where(exam_provider_id: @token.exam_provider_id).to_a
        found = @instruments.select { |instrument| ids.any? { |id| instrument.hl7_equipment_id.to_s.casecmp?(id) } }
        found.size == 1 ? found.first : nil
      end
    end
  end
end
