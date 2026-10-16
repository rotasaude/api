# Recebimento (spec §5.4): aceita, aceita com restrição (nota) ou rejeita
# com motivo ativo do laboratório. A rejeição cria a recoleta (amostra nova
# `awaiting`, recollection_of_id), passa os itens pendentes para ela e, no
# 21a, reabre a coleta (`scheduled` com motivo `recollection`, prazo novo).
module Lab
  module ReceiveSample
    DECISIONS = %w[accept reject accept_with_restriction].freeze
    FROM = %w[in_transit not_received].freeze

    module_function

    def call(barcode:, decision:, by:, reason_id: nil, restriction_note: nil, now: Time.current)
      sample = barcode.is_a?(String) && LabSample.find_by(barcode: barcode)
      return Result.fail(:not_found) unless sample

      req = sample.lab_requisition
      return Result.fail(:missing_role) unless Access.staff?(by) && Access.member?(by, req.exam_provider_id)
      return Result.fail(:invalid_decision) unless DECISIONS.include?(decision)

      note = restriction_note.is_a?(String) ? restriction_note.strip : ""
      return Result.fail(:restriction_note_required) if decision == "accept_with_restriction" && !note.length.between?(1, 300)

      reason = decision == "reject" && reason_id.is_a?(String) && LabRejectionReason.active.find_by(id: reason_id, exam_provider_id: req.exam_provider_id)
      return Result.fail(:reason_required) if decision == "reject" && !reason

      ApplicationRecord.transaction do
        # E2: requisição → item → pedido; a amostra depois da requisição.
        req.lock!
        sample.lock!
        receivable = FROM.include?(sample.status) || (sample.status == "awaiting" && sample.collected? && req.collection_place == "lab")
        next Result.fail(:invalid_transition, details: { status: sample.status }) unless receivable

        # E7: a 100ª amostra é recusada antes de qualquer escrita.
        next Result.fail(:too_many_samples) if decision == "reject" && next_index(req) > LabSample::MAX_PER_REQUISITION

        base = { received_by_user: by, received_at: now }
        recollection = nil
        case decision
        when "accept" then sample.update!(base.merge(status: "received"))
        when "accept_with_restriction" then sample.update!(base.merge(status: "accepted_with_restriction", restriction_note: note))
        else
          sample.update!(base.merge(status: "rejected", lab_rejection_reason: reason))
          recollection = recollect!(sample, req, by, now)
        end
        if recollection
          DomainEvents.publish("lab_sample.rejected", lab_sample_id: sample.id, lab_requisition_id: req.id, recollection_id: recollection.id)
        else
          DomainEvents.publish("lab_sample.received", lab_sample_id: sample.id, lab_requisition_id: req.id)
        end
        RequisitionStatus.refresh!(req)
        Result.ok(sample: sample, recollection: recollection)
      end || Result.fail(:invalid_transition, details: { status: sample.reload.status })
    end

    def recollect!(sample, req, by, now)
      pending = sample.items.where(status: "pending").order(:id).lock.to_a
      return nil if pending.empty?

      fresh = LabSample.create!(lab_requisition: req, barcode: LabSample.barcode_for(req.number, next_index(req)), material: sample.material,
                                container: sample.container, recollection_of: sample)
      place = req.collection_place == "lab" ? "#{req.exam_provider.name} — recoleta no laboratório" : "#{req.origin_unit.name} — recoleta na unidade"
      pending.each do |item|
        item.update!(lab_sample: fresh)
        order = item.exam_order
        next unless order.status == "collected"

        moved = Exams::Transition.call(order: order, kind: "scheduled", actor_user: by, reason: "recollection", now: now,
                                       changes: { scheduled_at: now, scheduled_place: place })
        raise ActiveRecord::Rollback if moved.failure?
      end
      fresh
    end

    def next_index(req) = req.samples.pluck(:barcode).map { |b| b[-2, 2].to_i }.max + 1

    private_class_method :recollect!, :next_index
  end
end
