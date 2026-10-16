# app/services/clinical_documents/verification.rb
# Conferência pública (ADR 0033; spec §6; contrato §7; Invariantes): só
# tipo, data, profissional e conselho, unidade, INICIAIS e ANO de nascimento,
# situação e modo. Nunca CID, medicamento, dias, CPF ou nome. Toda consulta
# deixa trilha sem dado pessoal (document_verification_lookups). O banco é o
# da cidade do host: o código de outra cidade simplesmente não existe aqui.
module ClinicalDocuments
  module Verification
    module_function

    # ADR 0037 (B18): o laudo do laboratório entra pela mesma página.
    def by_token(token)
      return trail!(nil, "token") unless token.is_a?(String) && token.match?(/\A[A-Za-z0-9_-]{22}\z/)

      record = public_documents.find_by(verification_token: token) || public_lab_reports.find_by(verification_token: token)
      trail!(record, "token")
    end

    # Nota #6: o código curto é único em cada tabela, não entre elas — o ano
    # desempata; se os dois baterem, nenhum (nunca mostrar o documento errado).
    def lookup(short_code:, birth_year:)
      code = Codes.normalize(short_code)
      year = birth_year.to_s.match?(/\A\d{4}\z/) ? birth_year.to_s.to_i : nil
      candidates = code && year ? [ public_documents.find_by(short_code: code), public_lab_reports.find_by(short_code: code) ].compact : []
      matching = candidates.select { |record| birth_year_of(record) == year }
      trail!(matching.one? ? matching.first : nil, "short_code")
    end

    # A assinatura gravada (só no modo digital), ou nil. O laudo não expõe PDF.
    def signature(document)
      return nil if document.is_a?(LabReport)

      document.digital? ? document.signed_signature : nil
    end

    def public_json(document)
      return lab_json(document) if document.is_a?(LabReport)

      signature = signature(document)
      author = document.author_user
      professional = author.professional
      status = if document.cancelled? then "cancelled"
               elsif document.digital? && signature.nil? then "awaiting_signature"
               else "valid"
               end
      json = { kind: document.kind, issued_at: document.issued_at.iso8601,
               # Só o nome do perfil profissional: sem perfil (a recepção), null —
               # nunca o e-mail da conta.
               professional: { name: professional&.professional_name.presence, council: Json.council(professional) },
               unit: document.attendance.health_unit.name,
               patient: { initials: Patients::Initials.call(person(document).display_name), birth_year: birth_year_of(document) },
               status: status, mode: document.issue_mode, simulated: signature&.simulated? || false }
      add_prescription_fields(json, document) if document.prescription?
      json[:cancelled_at] = document.cancelled_at.iso8601 if document.cancelled?
      json[:signed_pdf_url] = "#{document.verification_url}/signed.pdf" if signature && !document.cancelled?
      json
    end

    # Contrato §7: categoria em toda receita; numeração SNCR só no digital que a
    # tem. Nunca medicamento, CPF, endereço ou telefone.
    def add_prescription_fields(json, document)
      content = document.content_data
      json[:category] = content["category"] || (content["antimicrobial"] ? "antimicrobial" : "common")
      return unless document.digital? && content["sncr"].is_a?(Hash)

      json[:sncr] = { kind: content.dig("sncr", "kind"), number: content.dig("sncr", "number"),
                      simulated: content.dig("sncr", "simulated") == true }
    end

    def public_documents = ClinicalDocument.where.not(kind: "controlled_notification_record")

    # ADR 0037: laudo pendente, liberado ou retificado (o retirado não existe para fora).
    def public_lab_reports = LabReport.where(status: %w[pending_signature released rectified])

    # B18: tipo, data, quem liberou e conselho, o laboratório, INICIAIS e ANO
    # de nascimento, situação, modo e o hash do PDF. Nunca valor, nome, CPF ou PDF.
    def lab_json(report)
      content = report.content_data
      signer = content["released_by"]
      icp = report.signature_kind == "icp"
      signature = icp ? report.signature_request&.signature : nil
      status = { "pending_signature" => "awaiting_signature", "released" => "valid", "rectified" => "rectified" }.fetch(report.status)
      { kind: "lab_report", issued_at: (report.released_at || report.created_at).iso8601,
        professional: { name: signer["name"], council: "#{signer['council']}-#{signer['council_uf']} #{signer['council_number']}" },
        unit: content.dig("laboratory", "name"),
        patient: { initials: Patients::Initials.call(content.dig("patient", "name")), birth_year: birth_year_of(report) },
        status: status, mode: icp ? "digital" : "advanced", simulated: signature&.simulated? || false, pdf_sha256: report.pdf_sha256 }
    end

    def trail!(record, via)
      DocumentVerificationLookup.create!(clinical_document_id: (record.id if record.is_a?(ClinicalDocument)),
                                         lab_report_id: (record.id if record.is_a?(LabReport)),
                                         via: via, outcome: record ? "found" : "not_found")
      record
    end

    def person(record) = record.is_a?(LabReport) ? record.lab_requisition.patient : (record.patient || record.citizen)

    def birth_year_of(document)
      value = person(document).birth_date.to_s
      value.match?(/\A\d{4}-/) ? value[0, 4].to_i : nil
    end
    private_class_method :add_prescription_fields, :trail!, :person, :birth_year_of, :public_documents, :public_lab_reports, :lab_json
  end
end
