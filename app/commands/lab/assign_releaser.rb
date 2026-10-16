# Liga um liberador a um laboratório (contrato §3): papel lab_releaser,
# perfil com CRF/CRBM/CRM; um RT e um substituto ativos por laboratório.
module Lab
  module AssignReleaser
    module_function

    def call(user_id:, provider:, technical_lead:, technical_deputy:, by:)
      user = user_id.is_a?(String) && User.find_by(id: user_id, deactivated_at: nil)
      return Result.fail(:not_found) unless user
      return Result.fail(:user_missing_role) unless user.has_role?("lab_releaser")
      return Result.fail(:council_missing) unless Access.council(user)
      return Result.fail(:invalid_marks) unless [ true, false ].include?(technical_lead) && [ true, false ].include?(technical_deputy)
      return Result.fail(:invalid_marks) if technical_lead && technical_deputy

      releaser = ApplicationRecord.transaction do
        LabReleaser.create!(user: user, exam_provider: provider, technical_lead: technical_lead,
                            technical_deputy: technical_deputy, created_by_user: by).tap do |created|
          DomainEvents.publish("lab_releaser.assigned", lab_releaser_id: created.id, exam_provider_id: provider.id)
        end
      end
      Result.ok(releaser: releaser)
    rescue ActiveRecord::RecordNotUnique => e
      Result.fail({ "idx_lab_releasers_lead" => :lead_taken, "idx_lab_releasers_deputy" => :deputy_taken }
                    .find { |index, _| e.message.include?(index) }&.last || :already_assigned)
    end

    # I1: os laudos ICP ainda pendentes deste liberador neste laboratório saem
    # junto (B56: withdrawn, pedido resolvido com document_cancelled). Ordem de
    # trava única, a do FinalizeReport (ICP e avançada): requisição → ... →
    # liberador (FOR SHARE). Por isso as requisições desses laudos são travadas
    # (por id) ANTES da linha do liberador; travar o liberador primeiro fechava
    # um ciclo com a assinatura/liberação da mesma requisição (deadlock, 500).
    # O pedido que o job/lote está assinando agora fica de fora (SKIP LOCKED) —
    # esse cai na conferência do FinalizeReport e segue o mesmo caminho.
    # L6: idempotente — o liberador é relido sob a trava; se outro encerramento
    # passou primeiro, este não sobrescreve ended_at/ended_by nem publica de novo.
    def end!(releaser:, by:, now: Time.current)
      ApplicationRecord.transaction do
        pending = LabReport.where(released_by_user_id: releaser.user_id, exam_provider_id: releaser.exam_provider_id,
                                  status: "pending_signature", signature_kind: "icp").select(:id)
        LabRequisition.where(id: LabReport.where(id: pending).select(:lab_requisition_id)).order(:id).lock.pluck(:id)
        releaser.lock!
        next if releaser.ended_at

        releaser.update!(ended_at: now, ended_by_user: by)
        DomainEvents.publish("lab_releaser.ended", lab_releaser_id: releaser.id, exam_provider_id: releaser.exam_provider_id)
        SignatureRequest.pending.where(document_type: "LabReport", document_id: pending).order(:created_at, :id)
                        .lock("FOR UPDATE SKIP LOCKED").each do |request|
          Signatures::ToPaper.call(request, reason_code: "document_cancelled", now: now)
        end
      end
      Result.ok(releaser: releaser)
    end
  end
end
