# Revisão (spec §5.6; contrato §3; C-E4): RT ou substituto decide uma vez
# `kept` ou `rectify` (nota opcional até 1000, cifrada). `rectify` devolve o
# laudo liberado mais recente do item; a retificação é a do 21b.
module Lab
  module Qc
    module DecideReview
      DECISIONS = %w[kept rectify].freeze
      MAX_NOTE = 1000

      module_function

      def call(review:, decision:, note:, by:, now: Time.current)
        provider_id = review.lab_qc_block.lab_instrument.exam_provider_id
        # C-E36: revisão de outro laboratório → 404; no próprio, sem RT/substituto → 403.
        return Result.fail(:not_found) unless Lab::Access.member?(by, provider_id) || Lab::Access.admin?(by)
        return Result.fail(:missing_role) unless Lab::Access.technical?(by, provider_id)
        return Result.fail(:invalid_decision) unless DECISIONS.include?(decision)
        return Result.fail(:invalid_note) unless note.nil? || note.is_a?(String)

        text = note&.strip.presence
        return Result.fail(:invalid_note) if text && text.length > MAX_NOTE

        ApplicationRecord.transaction(requires_new: true) do
          review.lock!
          next Result.fail(:invalid_transition, details: { status: review.decision }) unless review.decision == "pending"

          review.update!(decision: decision, decided_by_user: by, decided_at: now, note: text)
          DomainEvents.publish("lab_qc_review.decided", lab_qc_review_item_id: review.id, decision: decision)
          report_id = if decision == "rectify"
                        LabReport.joins(:report_items).where(status: "released", lab_report_items: { lab_requisition_item_id: review.lab_requisition_item_id })
                                 .order(:version).last&.id
                      end
          Result.ok(review: review, report_id: report_id)
        end
      end
    end
  end
end
