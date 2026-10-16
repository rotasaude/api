# O laudo passa a valer (ADR 0037; contrato §9): na avançada, logo na
# liberação; no ICP, quando o 19b grava a assinatura (Task 18). Grava o PDF
# (o assinado, no ICP) em exam_files, marca os itens liberados e, no 21a,
# registra o resultado de cada exame (source lab, valores do JSON
# congelado, PDF próprio por resultado — B13) — ou, na retificação, o
# substitui (Exams::RectifyResult, Task 19) e o laudo anterior fica
# `rectified`. Tudo ou nada: qualquer recusa levanta Failed e desfaz (o
# savepoint próprio desfaz também dentro da transação de quem chama).
# Valor e PDF nunca vão a log, evento ou mensagem de erro.
module Lab
  module FinalizeReport
    class Failed < StandardError; end

    module_function

    def call(report:, pdf_bytes:, now: Time.current)
      ApplicationRecord.transaction(requires_new: true) do
        # E2/B38: requisição → itens → pedido (o laudo vem junto da requisição).
        report.lab_requisition.lock!
        report.lock!
        raise Failed, "invalid_transition" unless report.status == "pending_signature"
        # I1/B11: quem liberou ainda liberador ativo deste laboratório. FOR
        # SHARE: o AssignReleaser.end! (FOR UPDATE na linha) espera ou é esperado.
        raise Failed, "releaser_not_assigned" unless releaser_assigned?(report)

        file = store!(pdf_bytes, report, now)
        report.update!(status: "released", released_at: now, pdf_file_id: file.id, pdf_sha256: file.sha256)
        previous = report.replaces_report
        previous&.lock!&.update!(status: "rectified")
        provider = report.exam_provider
        # Itens por id; o pedido de cada um é travado pelo RegisterResult/RectifyResult.
        LabRequisitionItem.where(id: report.report_items.select(:lab_requisition_item_id)).order(:id).lock.each do |item|
          item.update!(status: "released") unless item.status == "released"
          values = values_for(report, item)
          flags = values.map { |v| v.delete("flag") }
          critical = flags.any? { |flag| LabResult::CRITICAL.include?(flag) }
          outcome = if previous
                      Exams::RectifyResult.call(order: item.exam_order, values: values, critical: critical, file: store!(pdf_bytes, report, now),
                                                laboratory_name: provider.name, by_user: report.released_by_user, by_provider: provider, now: now)
                    else
                      Exams::RegisterResult.call(order: item.exam_order, source: "lab", released_on: now.in_time_zone.to_date,
                                                 laboratory_name: provider.name, critical: critical, values: Result.ok(values: values),
                                                 file: store!(pdf_bytes, report, now), by_user: report.released_by_user,
                                                 by_provider: provider, now: now)
                    end
          raise Failed, outcome.reason.to_s if outcome.failure?
        end
        RequisitionStatus.refresh!(report.lab_requisition)
        if previous
          DomainEvents.publish("lab_report.rectified", lab_report_id: report.id, replaces_report_id: previous.id)
        else
          DomainEvents.publish("lab_report.released", lab_report_id: report.id, lab_requisition_id: report.lab_requisition_id,
                                                      signature_kind: report.signature_kind, partial: report.partial)
        end
      end
      Result.ok(report: report)
    rescue Failed => e
      Result.fail(e.message.to_sym)
    end

    # A forma `values` do 21a (+ "flag", tirado por quem chama), do JSON
    # congelado: o 21a recebe exatamente o que o laudo diz.
    #
    # C1: dois exames iguais (mesmo SIGTAP e versão) na mesma requisição. O
    # conteúdo não guarda o id do item; o ReportContent.build ordena os exames
    # por [nome, item.id], então, entre as entradas do mesmo SIGTAP+versão
    # (mesmo exame, mesmo nome), a k-ésima é do k-ésimo item do laudo
    # (lab_report_items) com esse SIGTAP+versão, em ordem de id.
    def values_for(report, item)
      exam = frozen_exam(report, item)
      raise Failed, "invalid_content" unless exam

      exam["components"].map do |c|
        { "key" => c["key"], "label" => c["name"], "value" => c["value"], "unit" => c["unit"], "loinc" => c["loinc"], "flag" => c["flag"] }
      end
    end

    def frozen_exam(report, item)
      key = ->(version) { [ version.lab_exam.sigtap_code, version.version ] }
      wanted = key.call(item.lab_exam_version)
      siblings = report.items.includes(lab_exam_version: :lab_exam).select { |i| key.call(i.lab_exam_version) == wanted }.sort_by(&:id)
      entries = report.content_data["exams"].select { |e| [ e["sigtap_code"], e["version"] ] == wanted }
      return nil unless entries.size == siblings.size

      entries[siblings.index { |i| i.id == item.id }]
    end

    def releaser_assigned?(report)
      user = report.released_by_user
      user.has_role?("lab_releaser") &&
        LabReleaser.active.where(user_id: user.id, exam_provider_id: report.exam_provider_id).lock("FOR SHARE").pick(:id).present?
    end

    def store!(bytes, report, now)
      stored = Exams::Files.store(bytes: bytes, content_type: "application/pdf", user: report.released_by_user)
      raise Failed, "missing_pdf" if stored.failure?

      stored.payload[:file].tap { |file| file.update!(consumed_at: now) }
    end
    private_class_method :store!, :frozen_exam, :releaser_assigned?
  end
end
