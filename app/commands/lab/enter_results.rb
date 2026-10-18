# Resultado digitado ou recebido (spec §5.6; contrato §5 e §7): a mesma
# regra para a tela e para a HL7. Trava a requisição e o item (E2); amostra
# aceita; componente da versão do item e não calculado; limites; marca pela
# faixa na data da coleta; calculados refeitos; item `typed` quando todos têm
# valor. Tudo ou nada. Nunca sobrescreve (só acrescenta). Componente repetido
# na mesma entrada é recusado (E5): a ordem de dois valores do mesmo
# componente na mesma mensagem não decide qual vale.
# Lote de reagente (ADR 0038): cada linha MEDIDA guarda o lote em uso do par
# aparelho × exame, lido UMA vez por chamada (a entrada inteira com o mesmo
# lote, mesmo que o lote troque no meio); nulo = sem rastreio. Leitura
# simples, sem trava e sem interruptor (Desvio 9): a ordem de travas do 21b
# (requisição → itens) não muda. O CALCULADO herda o lote comum dos insumos
# que valem (C-E30); insumos com lotes diferentes ou algum sem lote → nulo.
module Lab
  module EnterResults
    # Dashboard D7: item já liberado aceita valor novo (só vale numa retificação).
    # E6 (Task 13): pela HL7 só `pending`/`typed` devem entrar; `released` é só
    # da digitação. A Task 13 restringe no Hl7::Inbound; aqui fica como o plano.
    OPEN = %w[pending typed released].freeze

    # Um calculado que já valia ficaria velho se um insumo o tornasse
    # incalculável (divisão por zero, insumo não numérico): a entrada é recusada.
    Incomputable = Class.new(StandardError) do
      attr_reader :analyte_key

      def initialize(analyte_key)
        @analyte_key = analyte_key
        super("incomputable")
      end
    end

    module_function

    def call(item:, values:, source: "typed", by: nil, receipt: nil, now: Time.current)
      entries = Array(values).map { |v| v.respond_to?(:to_unsafe_h) ? v.to_unsafe_h : v }
      return Result.fail(:invalid_values) unless entries.size.between?(1, Analytes::MAX) && entries.all?(Hash)

      keys = entries.map { |entry| entry.stringify_keys["analyte_key"].to_s }
      repeated = keys.detect { |key| keys.count(key) > 1 }
      return Result.fail(:invalid_values, details: { analyte_key: repeated[0, 40] }) if repeated

      result = nil
      ApplicationRecord.transaction(requires_new: true) do
        # E2: requisição → item (por id) → pedido. A digitação não toca o pedido.
        item.lab_requisition.lock!
        item.lock!
        next result = Result.fail(:invalid_transition, details: { status: item.status }) unless OPEN.include?(item.status)
        # B54: o laudo ICP à espera da assinatura já tem o valor congelado.
        next result = Result.fail(:item_frozen) if Frozen.item?(item)
        next result = Result.fail(:sample_not_received) unless item.lab_sample.accepted?

        version = item.lab_exam_version
        ctx = context(item)
        lot_id = LabSupplyInUse.current_lot_id(instrument_id: version.lab_instrument_id, lab_exam_id: version.lab_exam_id)
        rows = []
        entries.each do |entry|
          entry = entry.stringify_keys
          analyte = version.analyte(entry["analyte_key"])
          if analyte.nil? || analyte["formula"].present?
            result = Result.fail(:unknown_analyte, details: { analyte_key: entry["analyte_key"].to_s[0, 40] })
            raise ActiveRecord::Rollback
          end
          normalized = Values.normalize(analyte, entry["value"])
          if normalized.failure?
            result = normalized
            raise ActiveRecord::Rollback
          end
          rows << create_row(item, analyte, normalized.payload, ctx, source, by, receipt, now, reagent_lot_id: lot_id)
        end
        rows.concat(recalculate!(item, source: source, by: by, receipt: receipt, now: now))
        DomainEvents.publish("lab_result.entered", lab_requisition_item_id: item.id, source: source)
        result = Result.ok(results: rows)
      end
      result
    rescue Incomputable => e
      Result.fail(:invalid_values, details: { analyte_key: e.analyte_key })
    end

    def context(item)
      req = item.lab_requisition
      on = (item.lab_sample.collected_at || item.lab_sample.received_at || Time.current).in_time_zone.to_date
      { sex: req.biological_sex, age_days: Reference.age_days(req.patient, on: on) }
    end

    # Refaz os calculados com as linhas que valem; marca o item digitado.
    def recalculate!(item, source:, by:, receipt:, now:)
      version = item.lab_exam_version
      ctx = context(item)
      effective = Effective.rows(item.reload)
      numbers = effective.transform_values { |row| row.value.match?(Values::NUMBER) ? BigDecimal(row.value.tr(",", ".")) : nil }.compact
      allowed = version.analytes.select { |a| a["value_type"] == "numeric" && a["formula"].nil? }.map { |a| a["key"] }
      created = version.calculated_analytes.filter_map do |analyte|
        current = effective[analyte["key"]]
        rpn = Formula.compile(analyte["formula"], allowed: allowed)
        number = Formula.evaluate(rpn, values: numbers)
        unless number
          raise Incomputable, analyte["key"] if current
          next
        end

        value = number.round(analyte["decimals"].to_i, BigDecimal::ROUND_HALF_UP)
        next if current && BigDecimal(current.value.tr(",", ".")) == value

        text = Values.normalize(analyte.merge("entry_min" => nil, "entry_max" => nil), value.to_s("F")).payload
        create_row(item, analyte, text, ctx, source, by, receipt, now, reagent_lot_id: inputs_lot_id(rpn, effective))
      end
      # Linhas novas valem já na resposta: a associação não pode ficar velha.
      item.results.reset
      item.update!(status: "typed") if item.status == "pending" && Effective.complete?(item)
      RequisitionStatus.refresh!(item.lab_requisition)
      created
    end

    # C-E30: o lote comum dos insumos que valem; divergentes ou algum sem lote → nil.
    def inputs_lot_id(rpn, effective)
      lots = rpn.filter_map { |kind, v| v if kind == :var }.uniq.map { |key| effective[key]&.reagent_lot_id }
      lots.uniq.size == 1 ? lots.first : nil
    end
    private_class_method :inputs_lot_id

    # created_at estritamente crescente por item+componente (E5): a "última
    # linha" é a última inserida, mesmo com `now` igual (item travado).
    # Carimbo lido aqui, com a trava já tomada (Lab::Clock; I1).
    def create_row(item, analyte, normalized, ctx, source, by, receipt, now, reagent_lot_id:)
      at = Clock.stamp(now, requisition_id: item.lab_requisition_id)
      last = item.results.where(analyte_key: analyte["key"]).maximum(:created_at)
      at = last + Rational(1, 1_000_000) if last && at <= last
      LabResult.create!(lab_requisition_item: item, analyte_key: analyte["key"], value: normalized[:value], unit: analyte["unit"],
                        flag: Reference.flag(analyte, normalized[:number], **ctx), source: source, lab_hl7_receipt: receipt,
                        entered_by_user: by, entered_at: now, created_at: at, reagent_lot_id: reagent_lot_id)
    end
    private_class_method :create_row
  end
end
