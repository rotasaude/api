# app/services/clinical_documents/verification.rb
# Conferência pública (ADR 0033; spec §6; contrato §7; Invariantes): só
# tipo, data, profissional e conselho, unidade, INICIAIS e ANO de nascimento,
# situação e modo. Nunca CID, medicamento, dias, CPF ou nome. Toda consulta
# deixa trilha sem dado pessoal (document_verification_lookups). O banco é o
# da cidade do host: o código de outra cidade simplesmente não existe aqui.
module ClinicalDocuments
  module Verification
    module_function

    def by_token(token)
      document = token.is_a?(String) && token.match?(/\A[A-Za-z0-9_-]{22}\z/) ? ClinicalDocument.where.not(kind: "controlled_notification_record").find_by(verification_token: token) : nil
      trail!(document, "token")
    end

    def lookup(short_code:, birth_year:)
      code = Codes.normalize(short_code)
      year = birth_year.to_s.match?(/\A\d{4}\z/) ? birth_year.to_s.to_i : nil
      document = code && year ? ClinicalDocument.where.not(kind: "controlled_notification_record").find_by(short_code: code) : nil
      document = nil if document && birth_year_of(document) != year
      trail!(document, "short_code")
    end

    # A assinatura gravada (só no modo digital), ou nil.
    def signature(document) = document.digital? ? document.signed_signature : nil

    def public_json(document)
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

    def trail!(document, via)
      DocumentVerificationLookup.create!(clinical_document_id: document&.id, via: via, outcome: document ? "found" : "not_found")
      document
    end

    def person(document) = document.patient || document.citizen

    def birth_year_of(document)
      value = person(document).birth_date.to_s
      value.match?(/\A\d{4}-/) ? value[0, 4].to_i : nil
    end
    private_class_method :add_prescription_fields, :trail!, :person, :birth_year_of
  end
end
