# app/commands/clinical_documents/issue.rb
# Emissão de documento clínico (ADR 0033; spec §4–§5; contrato §3). Da
# consulta, pela autora (rascunho ou finalizada — emitir depois não muda a
# consulta); do atendimento, só a declaração de comparecimento (recepção ou
# profissional da unidade), sempre em papel. Interruptor da assinatura,
# catálogo e listas Anvisa lidos FORA da transação (como Consultations::Finalize:
# Platform::Features engole StatementInvalid, e um erro do PG engolido dentro
# do savepoint abortaria a emissão). Numa transação só: documento, itens da
# receita, eventos da lista de medicamentos, pedido de assinatura e evento.
# O modo é decidido aqui e nunca convertido (só a volta ao papel do 19b).
module ClinicalDocuments
  module Issue
    DECLARATION_DAYS = 30

    module_function

    def call(kind:, content:, by:, consultation: nil, attendance: nil, replaces_document_id: nil, now: Time.current)
      kind = kind.to_s
      return invalid("kind") unless ClinicalDocument::KINDS.include?(kind)
      return invalid("kind") if attendance && kind != "attendance_declaration"

      signing = consultation ? Signatures::Gate.usable?(Current.city) : false
      platform = kind == "prescription" ? prescription_platform(content) : nil
      return platform if platform.is_a?(Result)

      result = nil
      ApplicationRecord.transaction(requires_new: true) do
        result = issue(kind, content, by, consultation, attendance, replaces_document_id, signing, platform, now)
        raise ActiveRecord::Rollback if result.failure?
      end
      result
    end

    def prescription_platform(content)
      return Result.fail(:catalog_unavailable) unless Medications::Search.available?

      items = Content::Input.object(content)["items"]
      ids = Array(items).filter_map do |item|
        reference = item.is_a?(Hash) && item["catalog_item"].is_a?(Hash) ? item["catalog_item"]["id"].to_s : nil
        reference if Uuid.valid?(reference)
      end
      { catalog: MedicationCatalogItem.where(id: ids.uniq).index_by(&:id), matcher: Medications::Substances.matcher }
    end

    def issue(kind, input, by, consultation, attendance, replaces_id, signing, platform, now)
      if consultation
        return Result.fail(:not_author) unless consultation.author_user_id == by.id

        attendance = consultation.attendance
        cbo = consultation.cbo_code
        return Result.fail(:cbo_not_allowed) unless Issuers.allowed?(kind, cbo)

        patient = Patient.lock.find(consultation.patient_id)
      else
        status, cbo = Issuers.declaration_staff(by, attendance)
        return Result.fail(status) unless status == :ok
        return Result.fail(:attendance_not_found_or_closed_long_ago) if attendance.checked_in_at < now - DECLARATION_DAYS.days

        patient = attendance.citizen.patient_id && Patient.lock.find(attendance.citizen.patient_id)
      end
      replaces = replaced(replaces_id, kind, attendance, by)
      return replaces if replaces.is_a?(Result)

      built = build(kind, input, consultation, attendance, patient, cbo, platform, now)
      return built if built.failure?

      content, rows, antimicrobial = built.payload.values_at(:content, :items, :antimicrobial)
      digital = signing && !antimicrobial && SignerCertificate.active.exists?(user_id: by.id)
      document = create!(kind: kind, patient_id: patient&.id, citizen_id: attendance.citizen_id, consultation: consultation,
                         attendance: attendance, author_user_id: by.id, cbo_code: cbo, issue_mode: digital ? "digital" : "paper",
                         replaces_document_id: replaces&.id, issued_at: now, content: content.to_json)
      return document if document.is_a?(Result)

      rows.each { |row| PrescriptionItem.create!(row.merge(clinical_document: document)) }
      failure = medications!(document, patient, rows, platform, by, now)
      return failure if failure

      Signatures::OpenRequest.call(document, now: now, usable: true) if digital
      link = consultation ? { consultation_id: consultation.id } : { attendance_id: attendance.id }
      DomainEvents.publish("clinical_document.issued", document_id: document.id, kind: kind, **link,
                                                       issue_mode: document.issue_mode)
      Result.ok(document: document)
    end

    def build(kind, input, consultation, attendance, patient, cbo, platform, now)
      today = now.in_time_zone.to_date
      result =
        case kind
        when "sick_note" then Content::SickNote.call(input, today: today)
        when "attendance_declaration" then Content::Declaration.call(input, attendance: attendance)
        when "exam_requisition" then Content::ExamRequisition.call(input, consultation: consultation)
        when "prescription"
          return Content::Prescription.call(input, role: Issuers.role(cbo), patient: patient, catalog: platform[:catalog],
                                                   matcher: platform[:matcher], today: today, city_cnpj: CityProfile.current&.cnpj)
        end
      result.ok? ? Result.ok(content: result.payload[:content], items: [], antimicrobial: false) : result
    end

    # "Cancelar e emitir outro" (spec §6): o substituído é um cancelado do
    # mesmo tipo, da mesma autora e do mesmo cidadão.
    def replaced(id, kind, attendance, by)
      return nil if id.nil?

      old = Uuid.valid?(id.to_s) ? ClinicalDocument.find_by(id: id) : nil
      valid = old&.cancelled? && old.kind == kind && old.author_user_id == by.id && old.citizen_id == attendance.citizen_id
      valid ? old : invalid("replaces_document_id")
    end

    # Código curto/token repetido (improvável): tenta de novo com outros. O
    # índice único em replaces_document_id fecha a corrida de dois "cancelar e
    # emitir outro" do mesmo documento: o segundo recebe 422, nunca 500.
    def create!(attrs)
      attempts = 0
      begin
        attempts += 1
        ApplicationRecord.transaction(requires_new: true) do
          ClinicalDocument.create!(attrs.merge(verification_token: Codes.token, short_code: Codes.short_code))
        end
      rescue ActiveRecord::RecordNotUnique => e
        return invalid("replaces_document_id") if e.message.include?("index_clinical_documents_on_replaces_document_id")
        raise unless attempts < 3 && e.message.match?(/short_code|verification_token/)

        retry
      end
    end

    def medications!(document, patient, rows, platform, by, now)
      rows.select { |row| row[:continuous] }.each do |row|
        result = Patients::ApplyMedicationEvent.call(
          patient: patient, action: "add", by: by, source: { document: document }, origin: "prescription",
          catalog_item: row[:medication_catalog_item_id] && platform[:catalog].fetch(row[:medication_catalog_item_id]),
          free_text: row[:free_text], dosage_summary: row[:dosage_instructions], continuous: true, on_active: :change,
          on: now.in_time_zone.to_date
        )
        return result if result.failure?
      end
      nil
    end

    def invalid(field) = Result.fail(:invalid_content, details: { field: field })
    private_class_method :prescription_platform, :issue, :build, :replaced, :create!, :medications!, :invalid
  end
end
