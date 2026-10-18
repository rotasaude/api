# Bloqueio por aparelho e analito (spec §5.3–§5.7; Desvio 7). Chamado com o
# aparelho travado (RecordValue). Abrir: um ativo por par (índice), revisão
# enfileirada. Fechar: corrida aceita, depois da abertura, com o valor mais
# recente de todos os níveis do material, nenhum reprovado e todos gravados
# depois da ação corretiva; sem ação, devolve o aviso (C-Q3).
module Lab
  module Qc
    module Blocks
      module_function

      def open!(instrument, analyte_key, run, now)
        active = LabQcBlock.active.find_by(lab_instrument_id: instrument.id, analyte_key: analyte_key)
        return active if active

        block = LabQcBlock.create!(lab_instrument: instrument, analyte_key: analyte_key, opened_by_run: run, opened_at: now)
        Reviews.enqueue!(block, run: run)
        DomainEvents.publish("lab_qc_block.opened", lab_qc_block_id: block.id, lab_instrument_id: instrument.id)
        block
      end

      def try_close!(instrument:, analyte_key:, run:, material:, by:, now:)
        block = LabQcBlock.active.find_by(lab_instrument_id: instrument.id, analyte_key: analyte_key)
        return [ nil, nil ] unless block
        return [ block, nil ] if run.id == block.opened_by_run_id || run.started_at < block.opened_at || !LabQcRun::ACCEPTED.include?(run.status)

        latest = LabQcValue.where(lab_qc_run_id: run.id, analyte_key: analyte_key, lab_qc_lot_id: material.lots.select(:id))
                           .order(:entered_at, :created_at).to_a.group_by(&:level).transform_values(&:last)
        return [ block, nil ] unless (material.levels - latest.keys).empty? && latest.values.none? { |v| v.outcome == "reject" }

        block.lock!
        return [ block, "corrective_action_required" ] if block.corrective_action.nil?
        return [ block, nil ] unless latest.values.all? { |v| v.entered_at >= block.corrective_action_at }

        block.update!(closed_by_run: run, closed_by_user: by, closed_at: now)
        DomainEvents.publish("lab_qc_block.closed", lab_qc_block_id: block.id, lab_instrument_id: instrument.id)
        [ block, nil ]
      end
    end
  end
end
