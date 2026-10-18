# Exceção do RT ou substituto (spec §5.5; contrato §3; C-E4): justificativa
# 1..1000, cifrada (em branco → justification_required; longa → invalid_reason,
# C-E11); o item é do laboratório, ainda não liberado, do aparelho e de um
# exame com o analito do bloqueio ATIVO (senão not_blocked) — a exceção é
# daquele bloqueio e não atravessa para o próximo. Uma por bloqueio e item
# (409). A liberação segue normal.
module Lab
  module Qc
    module GrantException
      MAX = 1000

      module_function

      def call(block_id:, item_id:, justification:, by:, now: Time.current)
        block = uuid?(block_id) && LabQcBlock.find_by(id: block_id)
        return Result.fail(:not_found) unless block

        provider_id = block.lab_instrument.exam_provider_id
        return Result.fail(:missing_role) unless Lab::Access.technical?(by, provider_id)

        text = justification.is_a?(String) ? justification.strip : ""
        return Result.fail(:justification_required) if text.empty?
        return Result.fail(:invalid_reason) if text.length > MAX

        item = uuid?(item_id) && LabRequisitionItem.includes(:lab_requisition, :lab_exam_version).find_by(id: item_id)
        return Result.fail(:not_found) unless item && item.lab_requisition.exam_provider_id == provider_id

        ApplicationRecord.transaction(requires_new: true) do
          block.lock!
          version = item.lab_exam_version
          covered = block.closed_at.nil? && version.lab_instrument_id == block.lab_instrument_id && version.analyte(block.analyte_key) &&
                    %w[pending typed].include?(item.reload.status)
          next Result.fail(:not_blocked) unless covered
          next Result.fail(:conflict) if LabQcException.exists?(lab_qc_block_id: block.id, lab_requisition_item_id: item.id)

          exception = LabQcException.create!(lab_qc_block: block, lab_requisition_item: item, justification: text, granted_by_user: by,
                                             granted_at: now, created_at: now)
          DomainEvents.publish("lab_qc_exception.granted", lab_qc_exception_id: exception.id, lab_qc_block_id: block.id,
                                                           lab_requisition_item_id: item.id)
          Result.ok(exception: exception)
        end
      end

      def uuid?(value) = value.is_a?(String) && value.match?(Exams::BaseController::UUID)
      private_class_method :uuid?
    end
  end
end
