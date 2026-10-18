# Valor de controle, digitado ou pela HL7 (spec §5.2–§5.7; ADR 0038; C-E14):
# trava o APARELHO (FOR UPDATE) e depois o lote de controle (FOR SHARE) —
# ordem aparelho → lote → requisição → itens → pedido (D11) —, acha a corrida
# (a dada, a do dia não reprovada ou uma nova), a referência vigente, calcula
# z (3 casas, ROUND_HALF_UP, ANTES de avaliar) e roda Westgard sobre a série
# do nível, os outros níveis da corrida e a série entre níveis; grava o valor
# (só acréscimo) com o lote de reagente em uso; piora a situação da corrida;
# reprovação abre o bloqueio (e enfileira a revisão); corrida aceita completa
# depois da ação corretiva fecha. Valor nunca em log/evento.
module Lab
  module Qc
    module RecordValue
      OUTCOME_STATUS = { "ok" => "approved", "warning" => "warning", "reject" => "rejected" }.freeze
      SERIES = 9

      module_function

      def call(instrument:, lot:, level:, analyte_key:, value:, source:, by: nil, receipt: nil, run_id: nil, run: nil, now: Time.current)
        raise ArgumentError, "RecordValue takes a BigDecimal value" unless value.is_a?(BigDecimal)

        material = lot.lab_qc_material
        return Result.fail(:invalid_instrument) unless instrument.active && instrument.exam_provider_id == material.exam_provider_id
        return Result.fail(:invalid_levels) unless material.levels.include?(level)

        entry = material.analyte_entry(analyte_key) # C-E12: a chave é única dentro do material
        return Result.fail(:no_target) unless entry

        result = nil
        # Savepoint próprio: dentro da transação da HL7, a recusa desfaz só o que é dela.
        ApplicationRecord.transaction(requires_new: true) do
          instrument.lock!
          lot = LabQcLot.lock("FOR SHARE").find(lot.id)
          next result = Result.fail(:lot_closed) if lot.status == "closed"
          next result = Result.fail(:expired_lot) if lot.expired?(now.in_time_zone.to_date)

          target = LabQcTarget.current(lot_id: lot.id, level: level, analyte_key: analyte_key, instrument_id: instrument.id)
          next result = Result.fail(:no_target) unless target

          run = resolve_run(instrument, run, run_id, by, now)
          next result = run if run.is_a?(Result)

          z = ((value - target.mean) / target.sd).round(3, BigDecimal::ROUND_HALF_UP)
          evaluation = Westgard.evaluate(z: z, series: series(instrument, run, lot, level, analyte_key), peers: peers(run, lot, level, analyte_key),
                                         cross: cross(instrument, run, level, analyte_key), enabled: LabQcRule.enabled_for(instrument.id, analyte_key))
          row = LabQcValue.create!(lab_qc_run: run, lab_qc_lot: lot, level: level, analyte_key: analyte_key, value: value, source: source,
                                   lab_hl7_receipt: receipt, z_score: z, lab_qc_target: target, rules_fired: evaluation.rules_fired,
                                   outcome: evaluation.outcome, entered_by_user: by, entered_at: now,
                                   reagent_lot_id: LabSupplyInUse.current_lot_id(instrument_id: instrument.id, lab_exam_id: entry["lab_exam_id"]))
          changed = advance!(run, evaluation.outcome, now)
          DomainEvents.publish("lab_qc_run.evaluated", lab_qc_run_id: run.id, status: run.status) if changed

          notice = nil
          if evaluation.outcome == "reject"
            block = Blocks.open!(instrument, analyte_key, run, now)
          else
            block, notice = Blocks.try_close!(instrument: instrument, analyte_key: analyte_key, run: run, material: material, by: by, now: now)
          end
          result = Result.ok(value: row, run: run, block: block, notice: notice)
        end
        result
      end

      # A corrida dada (HL7: mesmo reprovada); run_id (não reprovada); a do dia não reprovada; ou nova.
      def resolve_run(instrument, run, run_id, by, now)
        return run if run

        if run_id
          found = LabQcRun.find_by(id: run_id, lab_instrument_id: instrument.id)
          return Result.fail(:not_found) unless found
          return Result.fail(:invalid_transition, details: { status: found.status }) if found.status == "rejected"

          return found
        end
        day = now.in_time_zone.to_date
        LabQcRun.where(lab_instrument_id: instrument.id, started_at: day.beginning_of_day..day.end_of_day).where.not(status: "rejected")
                .order(:started_at, :created_at).last ||
          LabQcRun.create!(lab_instrument: instrument, sector: instrument.sector, status: "open", started_at: now, opened_by_user: by)
      end

      # Desvio 5: até 9 z anteriores do mesmo lote, nível, analito e aparelho,
      # em corridas não reprovadas (warning entra), sem a corrida atual, mais antigo primeiro.
      def series(instrument, run, lot, level, analyte_key)
        accepted_values(instrument, analyte_key).where.not(lab_qc_run_id: run.id).where(lab_qc_lot_id: lot.id, level: level)
                                                .order(entered_at: :desc, created_at: :desc).limit(SERIES).pluck(:z_score).reverse
      end

      # O z mais recente de cada OUTRO nível do analito nesta corrida.
      def peers(run, lot, level, analyte_key)
        LabQcValue.where(lab_qc_run_id: run.id, lab_qc_lot_id: lot.id, analyte_key: analyte_key).where.not(level: level)
                  .order(:entered_at, :created_at).to_a.group_by(&:level).values.map { |rows| rows.last.z_score }
      end

      # C-E14: até 9 z anteriores do analito no aparelho somando os níveis, em
      # ordem cronológica: corridas não reprovadas anteriores e, desta, os outros níveis.
      def cross(instrument, run, level, analyte_key)
        others = LabQcValue.where(lab_qc_run_id: run.id, analyte_key: analyte_key).where.not(level: level)
        accepted_values(instrument, analyte_key).where.not(lab_qc_run_id: run.id).or(others)
                                                .order(entered_at: :desc, created_at: :desc).limit(SERIES).pluck(:z_score).reverse
      end

      def accepted_values(instrument, analyte_key)
        LabQcValue.where(analyte_key: analyte_key, lab_qc_run_id: LabQcRun.where(lab_instrument_id: instrument.id).where.not(status: "rejected").select(:id))
      end

      def advance!(run, outcome, now)
        wanted = OUTCOME_STATUS.fetch(outcome)
        status = LabQcRun::SEVERITY[wanted] > LabQcRun::SEVERITY[run.status] ? wanted : run.status
        changed = status != run.status
        run.update!(status: status, evaluated_at: now)
        changed
      end
      private_class_method :resolve_run, :series, :peers, :cross, :accepted_values, :advance!
    end
  end
end
