# Entrada HL7 (ADR 0037; contrato §7, B26, E6): sempre responde ACK/RSP.
# Amostra só do laboratório do token, aceita; exame pelo código do aparelho
# da versão do item; componente da versão e não calculado; unidade igual
# quando vem; mesma regra da digitação. A mensagem é conferida INTEIRA: toda
# recusa é coletada (forma + banco), uma ERR por recusa na ordem dos
# segmentos, e nada é gravado se houver qualquer uma (nem o recibo). Pela HL7
# só item pending/typed recebe resultado (item_not_open); liberado só pela
# digitação. MSH-10 já aceito = AA sem efeito. Bruto cifrado em
# lab_hl7_receipts. Nada da mensagem em log.
module Lab
  module Hl7
    module Inbound
      TYPES = %w[QBP^Q11^QBP_Q11 OUL^R22^OUL_R22].freeze
      OPEN_STATUSES = %w[pending typed].freeze
      Entry = Data.define(:order, :item, :values)

      module_function

      def call(raw:, token:, city_slug:, fake_allowed:, now: Time.current)
        message = begin
          Message.parse(raw)
        rescue Invalid
          return Builder.ack(request: nil, code: "AR", city_slug: city_slug, now: now, errors: [ error("invalid_message", nil) ])
        end
        ar = ->(code, location = nil) { Builder.ack(request: message, code: "AR", city_slug: city_slug, now: now, errors: [ error(code, location) ]) }
        return ar.call("unsupported_version", "MSH^1^12") unless message.version == "2.5.1"
        return ar.call("token_revoked") if token.revoked?
        return ar.call("feature_disabled") if token.simulated && !fake_allowed
        return ar.call("unsupported_message_type", "MSH^1^9") unless TYPES.include?(message.type)
        return ar.call("invalid_message", "MSH^1^10") unless message.control_id.length.between?(1, 64)

        message.type.start_with?("QBP") ? worklist(message, token, city_slug, now) : results(message, raw, token, city_slug, now)
      end

      def error(code, location) = Builder::Error.new(code: code, location: location)

      def worklist(message, token, city_slug, now)
        qpd = message.first("QPD")
        tag = message.field(qpd, 2).to_s
        barcode = message.field(qpd, 3).to_s
        reply = lambda do |code, errors: [], sample: nil, items: []|
          Builder.rsp(request: message, code: code, city_slug: city_slug, query_tag: tag, barcode: barcode, now: now,
                      errors: errors, sample: sample, items: items)
        end
        sample = find_sample(token, barcode)
        return reply.call("AE", errors: [ error("unknown_barcode", "QPD^1^3") ]) unless sample
        return reply.call("AE", errors: [ error("sample_not_received", "QPD^1^3") ]) unless sample.accepted?

        items = sample.items.where(status: "pending").includes(lab_exam_version: :lab_exam).to_a
                      .select { |i| i.lab_exam_version.instrument_test_code.present? }
        reply.call("AA", sample: sample, items: items)
      end

      def results(message, raw, token, city_slug, now)
        ack = ->(code, errors = []) { Builder.ack(request: message, code: code, city_slug: city_slug, now: now, errors: errors) }
        return ack.call("AA") if LabHl7Receipt.exists?(lab_middleware_token_id: token.id, control_id: message.control_id)

        structural = message.structure_errors
        return ack.call("AR", structural.presence || [ error("invalid_message", "SPM^1^2") ]) if message.specimens.empty?

        errors = structural.dup
        # requires_new: o Rollback desfaz recibo e linhas mesmo dentro de outra transação.
        ApplicationRecord.transaction(requires_new: true) do
          receipt = LabHl7Receipt.create!(lab_middleware_token: token, control_id: message.control_id, message_type: message.type,
                                          raw: raw.to_s.dup.force_encoding(Encoding::UTF_8), created_at: now)
          errors.concat(Application.new(message, token, receipt, now, write: structural.empty?).run)
          raise ActiveRecord::Rollback if errors.any?
        end
        return ack.call("AA") if errors.empty?

        # B50: erro de estrutura (invalid_message) é sempre AR; AE só para recusa de conteúdo.
        ack.call(errors.any? { |e| e.code == "invalid_message" } ? "AR" : "AE", ordered(message, errors))
      rescue ActiveRecord::RecordNotUnique => e
        raise unless e.message.include?("idx_lab_hl7_receipts_control")

        ack.call("AA") # a mesma mensagem chegou duas vezes ao mesmo tempo: a outra gravou
      end

      # B26: uma ERR por recusa (sem repetir a mesma), na ordem dos segmentos.
      def ordered(message, errors)
        position = {}
        counts = Hash.new(0)
        message.segments.each_with_index { |segment, i| position[[ segment.first, (counts[segment.first] += 1) ]] ||= i }
        errors.uniq { |e| [ e.code, e.location ] }.each_with_index.sort_by do |e, i|
          name, index, field = e.location.to_s.split("^")
          [ position[[ name, index.to_i ]] || Float::INFINITY, field.to_i, i ]
        end.map(&:first)
      end

      def find_sample(token, barcode)
        return nil unless barcode.to_s.match?(/\A\d{10}\z/)

        LabSample.joins(:lab_requisition).where(lab_requisitions: { exam_provider_id: token.exam_provider_id }).find_by(barcode: barcode)
      end

      # Confere (e, sem recusa, grava) cada SPM/OBR/OBX do OUL^R22 dentro da transação do chamador.
      class Application
        def initialize(message, token, receipt, now, write:)
          @message = message
          @token = token
          @receipt = receipt
          @now = now
          @write = write
          @errors = []
        end

        def run
          plan = resolve
          items = lock(plan)
          plan.each { |step| apply(step, items.fetch(step[:item].id)) }
          @errors
        end

        private

        def error(code, location) = Builder::Error.new(code: code, location: location)

        # Amostra e exame de cada pedido (leitura); recusas de amostra/exame.
        def resolve
          plan = []
          claimed = Set.new
          @message.specimens.each do |specimen|
            where = "SPM^#{specimen.index}^2"
            sample = Inbound.send(:find_sample, @token, @message.barcode(specimen))
            next @errors << error("unknown_barcode", where) unless sample
            next @errors << error("sample_not_received", where) unless sample.accepted?

            items = sample.items.includes(:lab_exam_version).to_a
            specimen.orders.each do |order|
              code = @message.field(order.obr, 4, 1).to_s
              found = items.select { |i| i.lab_exam_version.instrument_test_code.present? && i.lab_exam_version.instrument_test_code.casecmp?(code) }
              item = found.find { |i| OPEN_STATUSES.include?(i.status) } || found.first
              next @errors << error("exam_not_in_version", "OBR^#{order.index}^4") unless item

              # Dois OBR do mesmo exame na mensagem: a ordem não decide qual vale (E5/B26).
              next @errors << error("invalid_value", "OBR^#{order.index}^4") unless claimed.add?(item.id)

              plan << { order: order, item: item }
            end
          end
          plan
        end

        # E2: requisição → itens, ambos por id (ordem estável entre mensagens).
        def lock(plan)
          return {} if plan.empty?

          LabRequisition.where(id: plan.map { |s| s[:item].lab_requisition_id }.uniq).order(:id).lock.to_a
          LabRequisitionItem.where(id: plan.map { |s| s[:item].id }.uniq).order(:id).lock.index_by(&:id)
        end

        def apply(step, item)
          order = step[:order]
          where = "OBR^#{order.index}^4"
          return @errors << error("item_not_open", where) unless OPEN_STATUSES.include?(item.status)

          entries, found = check(order, item.lab_exam_version)
          @errors.concat(found)
          return if found.any? || entries.empty? || !@write

          entered = EnterResults.call(item: item, values: entries.map { |e| e.except("_index") }, source: "hl7", receipt: @receipt, now: @now)
          @errors << refusal(entered, entries, order) if entered.failure?
        end

        def check(order, version)
          entries = []
          found = []
          seen = Set.new
          order.results.each do |obx|
            segment = obx.segment
            key = @message.field(segment, 3, 1).to_s
            next if key.blank? # forma: já recusado em structure_errors

            analyte = version.analyte(key)
            at = ->(field) { "OBX^#{obx.index}^#{field}" }
            next found << error("unknown_analyte", at.call(3)) if analyte.nil? || analyte["formula"].present?

            unit = @message.field(segment, 6, 1).to_s
            # Unidade diferente: o valor está em outra escala, a faixa não se aplica.
            next found << error("unit_mismatch", at.call(6)) if unit.present? && analyte["unit"].present? && unit != analyte["unit"]
            next found << error("invalid_value", at.call(5)) unless seen.add?(key)

            value = @message.field(segment, 5, 1).to_s
            normalized = Values.normalize(analyte, value)
            next found << error(normalized.reason.to_s, at.call(5)) if normalized.failure?

            entries << { "analyte_key" => key, "value" => value, "_index" => obx.index }
          end
          [ entries, found ]
        end

        # Recusa vinda da digitação (calculado incomputável etc.): no OBX do componente, ou no último.
        def refusal(entered, entries, order)
          reason = entered.reason.to_s
          index = entries.find { |e| e["analyte_key"] == entered.details&.dig(:analyte_key) }&.fetch("_index") || entries.last["_index"]
          return error(reason, "OBX^#{index}^#{reason == 'unknown_analyte' ? 3 : 5}") if %w[out_of_entry_range invalid_value unknown_analyte].include?(reason)
          return error("invalid_value", "OBX^#{index}^5") if reason == "invalid_values"
          return error("item_not_open", "OBR^#{order.index}^4") if reason == "invalid_transition"
          return error("sample_not_received", "OBR^#{order.index}^4") if reason == "sample_not_received"

          error("invalid_message", "OBR^#{order.index}^1")
        end
      end

      private_class_method :worklist, :results, :ordered, :find_sample
    end
  end
end
