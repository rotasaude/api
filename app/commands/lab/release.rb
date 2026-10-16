# Liberação (contrato §5, B14; spec §5.7; ADR 0037 Invariantes): só o
# liberador ligado ao laboratório, com conselho do laboratório; médico (CRM)
# só ICP. Avançada: TOTP do momento, consumido; o laudo nasce e já vale. ICP:
# digital_signature utilizável e certificado ativo; o laudo nasce
# pending_signature e o pedido do 19b vai na mesma transação — sem pedido
# criado, nada fica esperando (D5/E14). Crítico sem aviso não bloqueia (vai à
# fila). Interruptor lido fora da transação.
#
# Ordem das recusas (D4/E3): papel, conselho e tipo de assinatura; depois,
# sob a trava, os itens, o RT e o laboratório; o TOTP só é consumido no fim,
# então uma recusa nunca queima o código. Travas na ordem única E2/B38:
# requisição → itens (por id) → pedidos (no Exams::RegisterResult).
#
# Retificação (rectifies:, ruling I1 da Task 19): o laudo novo SUBSTITUI o
# anterior inteiro — cobre todos os itens dele, os que não mudaram congelados
# de novo com os mesmos valores; `item_ids` são os itens que MUDARAM (só esses
# ganham resultado novo no 21a, no FinalizeReport). Item listado sem mudança
# ou item não listado que mudou desde o laudo anterior: 422
# rectify_items_mismatch { unchanged:, unlisted: }.
module Lab
  module Release
    SIGNATURES = %w[icp advanced].freeze
    MAX_ITEMS = 50

    module_function

    def call(requisition:, item_ids:, signature:, totp:, by:, now: Time.current, rectifies: nil, reason: nil, contacts: nil)
      provider = requisition.exam_provider
      return Result.fail(:missing_role) unless Access.releaser_link(by, provider.id)

      council = Access.council(by)
      return Result.fail(:council_missing) unless council
      return Result.fail(:invalid_signature) unless SIGNATURES.include?(signature)
      return Result.fail(:icp_required) if council == "CRM" && signature == "advanced"
      return Result.fail(:signature_unavailable) if signature == "icp" && !icp_available?

      ids = Array(item_ids).map { |id| id.to_s.downcase }.uniq
      return Result.fail(:invalid_transition) unless ids.size.between?(1, MAX_ITEMS)

      result = nil
      # Savepoint próprio: dentro da transação de quem chama, o Rollback desfaz
      # o laudo e os itens em vez de ser engolido.
      ApplicationRecord.transaction(requires_new: true) do
        requisition.lock!
        covered = rectifies ? (rectifies.report_items.pluck(:lab_requisition_item_id) | ids) : ids
        items = LabRequisitionItem.where(lab_requisition_id: requisition.id, id: covered).order(:id).lock
                                  .includes(:lab_sample, :results, lab_exam_version: :lab_exam).to_a
        refusal = item_refusal(items, covered, ids, rectifies)
        next result = refusal if refusal

        lead = technical_lead(provider)
        next result = Result.fail(:technical_lead_missing) unless lead
        next result = Result.fail(:laboratory_incomplete) unless ReportContent.laboratory_ready?(provider)

        if signature == "icp"
          next result = Result.fail(:no_active_certificate) unless SignerCertificate.active.exists?(user_id: by.id)
        else
          step = by.mfa_enrolled? ? Mfa::Verify.totp_step_for(by, totp.to_s) : nil
          next result = Result.fail(:mfa_required) unless by.consume_totp_step!(step)
        end

        others = requisition.items.reload.select(&:active?).reject { |i| covered.include?(i.id) }
        partial = others.any? { |i| i.status != "released" }
        built = ReportContent.build(requisition: requisition, items: items, released_by: by, lead: lead, partial: partial,
                                    signature_kind: signature, issued_at: now, replaces: rectifies, reason: reason)
        report = create_report!(requisition, provider, built, by, signature, partial, rectifies, reason, contacts)
        items.each { |item| LabReportItem.create!(lab_report: report, lab_requisition_item: item, created_at: now) }
        if signature == "advanced"
          finalized = FinalizeReport.call(report: report, pdf_bytes: ReportPdf.call(report.reload), now: now)
          if finalized.failure?
            result = finalized
            raise ActiveRecord::Rollback
          end
        elsif Signatures::OpenRequest.call(report, now: now, usable: true) != :created
          # :manual/:unusable/:exists: o laudo ficaria pending_signature sem
          # pedido e o item congelado para sempre (B54). Desfaz tudo.
          result = Result.fail(:no_active_certificate)
          raise ActiveRecord::Rollback
        end
        result = Result.ok(report: report.reload)
      end
      result
    rescue ReportContent::Invalid
      Result.fail(:invalid_content)
    end

    # B14: ICP só com digital_signature utilizável na cidade.
    def icp_available? = Signatures::Gate.usable?(Current.city)

    # Itens desta requisição, todos na situação certa, com amostra aceita, com
    # cada componente valendo (B30) e fora de laudo pending_signature (B54).
    # Na retificação: o laudo anterior ainda `released` (relido sob a trava da
    # requisição — duas retificações simultâneas: a segunda é 409, não 500),
    # `ids` dentro dele (B42) e só os listados mudaram (I1).
    def item_refusal(items, covered, ids, rectifies)
      if rectifies
        rectifies.reload
        return Result.fail(:invalid_transition, details: { status: rectifies.status }) unless rectifies.status == "released"
        return Result.fail(:invalid_transition, details: { status: rectifies.status }) unless (ids - rectifies.report_items.pluck(:lab_requisition_item_id)).empty?
      end
      expected = rectifies ? "released" : "typed"
      bad = items.find { |i| i.status != expected || !i.lab_sample.accepted? }
      return Result.fail(:invalid_transition, details: { status: bad&.status }) if items.size != covered.size || bad
      return Result.fail(:invalid_transition, details: { status: "pending_signature" }) if Frozen.item?(covered)

      incomplete = items.find { |i| !Effective.complete?(i) }
      return Result.fail(:invalid_transition, details: { status: incomplete.status }) if incomplete

      return nil unless rectifies

      # Fix round 2: listado sem mudança e não listado que mudou → um código só,
      # com os ids, para o dashboard explicar e marcar os itens.
      changed = items.select { |i| changed?(i, rectifies) }.map(&:id)
      unchanged = (ids - changed).sort
      unlisted = (changed - ids).sort
      return nil if unchanged.empty? && unlisted.empty?

      Result.fail(:rectify_items_mismatch, details: { unchanged: unchanged, unlisted: unlisted })
    end

    # O exame do item como sairia agora × como está congelado no laudo anterior.
    def changed?(item, report)
      JSON.parse(ReportContent.exam(item).to_json) != FinalizeReport.frozen_exam(report, item)
    end

    # RT ativo do laboratório, com conselho do laboratório no perfil (B46: sem
    # RT entre encerrar e designar de novo, a liberação recusa).
    def technical_lead(provider)
      lead = LabReleaser.active.find_by(exam_provider_id: provider.id, technical_lead: true)&.user
      lead if lead && Access.council(lead)
    end

    def create_report!(requisition, provider, built, by, signature, partial, rectifies, reason, contacts)
      attempts = 0
      begin
        attempts += 1
        ApplicationRecord.transaction(requires_new: true) do
          LabReport.create!(lab_requisition: requisition, exam_provider: provider,
                            version: requisition.reports.maximum(:version).to_i + 1,
                            replaces_report: rectifies, partial: partial, status: "pending_signature", signature_kind: signature,
                            released_by_user: by, content: built.json, content_sha256: built.sha256,
                            verification_token: ClinicalDocuments::Codes.token, short_code: ClinicalDocuments::Codes.public_short_code,
                            rectification_reason: reason, rectification_contacts: contacts&.to_json)
        end
      rescue ActiveRecord::RecordNotUnique => e
        raise unless attempts < 3 && e.message.match?(/short_code|verification_token/)

        retry
      end
    end
    private_class_method :icp_available?, :item_refusal, :changed?, :technical_lead, :create_report!
  end
end
