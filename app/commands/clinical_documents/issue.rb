# app/commands/clinical_documents/issue.rb
# Emissão de documento clínico (ADR 0033 + ADR 0034; spec 19c §4–§5, 19d
# §5–§6; contrato §3 do 19c, §2/§12 do 19d). Da consulta, pela autora
# (rascunho ou finalizada — emitir depois não muda a consulta); do
# atendimento, só a declaração de comparecimento (recepção ou profissional da
# unidade), sempre em papel. Interruptores, catálogo, listas Anvisa e o
# contato do prescritor lidos FORA da transação (como Consultations::Finalize:
# Platform::Features engole StatementInvalid, e um erro do PG engolido dentro
# do savepoint abortaria a emissão). Numa transação só: documento, itens da
# receita, número SNCR (tirado com FOR UPDATE SKIP LOCKED e marcado used — a
# falha devolve por rollback), eventos da lista de medicamentos, pedido de
# assinatura (só no digital) e eventos. O modo é decidido aqui e nunca
# convertido (só a volta ao papel do 19b, que não grava paper_reason); o
# motivo do papel é gravado no documento e volta na resposta (Desvio 10).
# Nenhum número SNCR, CPF ou endereço em evento, log ou erro.
module ClinicalDocuments
  module Issue
    DECLARATION_DAYS = 30
    SNCR_KINDS = { "special_control" => "rce", "antimicrobial" => "ret" }.freeze
    CATALOG_KINDS = %w[prescription controlled_notification_record].freeze

    # Decisões lidas fora da transação. `contact` (endereço e telefone do
    # prescritor) fica fora do inspect.
    Context = Data.define(:signing, :controlled, :simulated, :platform, :contact) do
      def inspect = "#<ClinicalDocuments::Issue::Context signing=#{signing} controlled=#{controlled} simulated=#{simulated}>"
      alias_method :to_s, :inspect
      def pretty_print(pp) = pp.text(inspect)
    end

    module_function

    def call(kind:, content:, by:, consultation: nil, attendance: nil, replaces_document_id: nil, now: Time.current)
      kind = kind.to_s
      return invalid("kind") unless ClinicalDocument::KINDS.include?(kind)
      return invalid("kind") if attendance && kind != "attendance_declaration"

      controlled = consultation ? ControlledPrescriptions::Gate.usable?(Current.city) : false
      if kind == "controlled_notification_record" && !controlled
        return Result.fail(:feature_disabled, details: { feature: ControlledPrescriptions::Gate::KEY })
      end

      # A checagem de CBO do registro vem antes de ler o catálogo da plataforma:
      # catálogo indisponível não vira 503 para quem nem poderia emitir.
      if kind == "controlled_notification_record" && consultation&.author_user_id == by.id &&
         !Issuers.allowed?(kind, consultation.cbo_code)
        return Result.fail(:cbo_not_allowed)
      end

      platform = CATALOG_KINDS.include?(kind) ? prescription_platform(content) : nil
      return platform if platform.is_a?(Result)

      ctx = Context.new(signing: consultation ? Signatures::Gate.usable?(Current.city) : false, controlled: controlled,
                        simulated: controlled && Sncr::Mock.on?(Current.city), platform: platform,
                        contact: (by.professional&.prescriber_contact if consultation && kind == "prescription"))
      result = nil
      ApplicationRecord.transaction(requires_new: true) do
        result = issue(kind, content, by, consultation, attendance, replaces_document_id, ctx, now)
        raise ActiveRecord::Rollback if result.failure?
      end
      result
    end

    # Desvio 10: o modo e o motivo do papel, na ordem fixada — interruptor da
    # receita controlada, enfermagem no antimicrobiano, só texto livre
    # (free_text_items), assinatura, certificado
    # (o número SNCR vem depois, na transação). O registro da Notificação é
    # sempre papel, sem motivo.
    def decide(kind:, category:, role:, ctx:, certificate:, paper_only: false)
      return [ :paper, nil ] if kind == "controlled_notification_record"

      if category == "antimicrobial"
        return [ :paper, :feature_disabled ] unless ctx.controlled
        return [ :paper, :nurse_antimicrobial ] if role == :nurse
        # Só itens em texto livre (antimicrobiano, com ou sem texto livre comum; §12,
        # docs 89f6748): papel do 19c, sem tirar número, motivo próprio.
        return [ :paper, :free_text_items ] if paper_only
      end
      return [ :paper, :signature_unavailable ] unless ctx.signing
      return [ :paper, :no_certificate ] unless certificate

      [ :digital, nil ]
    end

    def prescription_platform(content)
      return Result.fail(:catalog_unavailable) unless Medications::Search.available?

      input = Content::Input.object(content)
      entries = Array(input["items"]) + [ input["item"] ].compact
      ids = entries.filter_map do |item|
        reference = item.is_a?(Hash) && item["catalog_item"].is_a?(Hash) ? item["catalog_item"]["id"].to_s : nil
        reference if Uuid.valid?(reference)
      end
      { catalog: MedicationCatalogItem.where(id: ids.uniq).index_by(&:id), matcher: Medications::Substances.matcher }
    end

    def issue(kind, input, by, consultation, attendance, replaces_id, ctx, now)
      if consultation
        # Card api#51: autoria e status relidos sob a trava da consulta (lock!
        # relê) — a designação ou o descarte entre a leitura e aqui vence. Ordem
        # de travas: consulta → paciente (atendimento → consulta → paciente no
        # Finalize, Discard e Reassign; aqui o atendimento não é travado).
        consultation.lock!
        # Descartada (card api#51) é casca: inexistente para emitir.
        return Result.fail(:not_found) if consultation.discarded?
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

      built = build(kind, input, consultation, attendance, patient, cbo, ctx, now)
      return built if built.failure?

      content, rows, category, paper_only = built.payload.values_at(:content, :items, :category, :paper_only)
      record_item = built.payload[:catalog_item]
      mode, reason =
        if consultation
          decide(kind: kind, category: category, role: Issuers.role(cbo), ctx: ctx, paper_only: paper_only == true,
                 certificate: SignerCertificate.active.exists?(user_id: by.id))
        else
          [ :paper, nil ]
        end
      number = nil
      if mode == :digital && SNCR_KINDS.key?(category)
        number = Sncr::Stock.take!(user: by, kind: SNCR_KINDS.fetch(category), simulated: ctx.simulated)
        mode, reason = :paper, :no_sncr_number unless number
      end
      # §12: a RET sem contato do prescritor só é recusada quando sairia digital
      # (o número tirado volta por rollback).
      return Result.fail(:prescriber_address_missing) if category == "antimicrobial" && mode == :digital && ctx.contact.nil?

      content = content.merge("sncr" => { "kind" => number.kind, "number" => number.number, "simulated" => number.simulated }) if number
      document = create!(kind: kind, patient_id: patient&.id, citizen_id: attendance.citizen_id, consultation: consultation,
                         attendance: attendance, author_user_id: by.id, cbo_code: cbo, issue_mode: mode.to_s,
                         paper_reason: reason&.to_s, replaces_document_id: replaces&.id, issued_at: now,
                         content: content.to_json)
      return document if document.is_a?(Result)

      rows.each { |row| PrescriptionItem.create!(row.merge(clinical_document: document)) }
      Sncr::Stock.use!(number, document: document, now: now) if number
      failure = medications!(document, patient, rows, ctx.platform, by, now)
      return failure if failure

      # O registro da Notificação entra na lista de medicamentos (não contínuo).
      failure = record_medication!(document, patient, record_item, content, by, now) if record_item
      return failure if failure

      # Papel nunca prepara assinatura (nem pedido, nem SignJob, nem canônico).
      Signatures::OpenRequest.call(document, now: now, usable: true) if mode == :digital
      publish!(document, kind, category, consultation, attendance)
      if kind == "controlled_notification_record"
        DomainEvents.publish("controlled_notification.recorded", document_id: document.id,
                                                                  notification_type: content["notification_type"])
      end
      Result.ok(document: document, paper_reason: reason&.to_s)
    end

    def publish!(document, kind, category, consultation, attendance)
      link = consultation ? { consultation_id: consultation.id } : { attendance_id: attendance.id }
      payload = { document_id: document.id, kind: kind, **link, issue_mode: document.issue_mode }
      payload[:category] = category if kind == "prescription"
      DomainEvents.publish("clinical_document.issued", **payload)
    end

    def build(kind, input, consultation, attendance, patient, cbo, ctx, now)
      today = now.in_time_zone.to_date
      result =
        case kind
        when "sick_note" then Content::SickNote.call(input, today: today)
        when "attendance_declaration" then Content::Declaration.call(input, attendance: attendance)
        when "exam_requisition" then Content::ExamRequisition.call(input, consultation: consultation)
        when "prescription"
          return Content::Prescription.call(input, role: Issuers.role(cbo), patient: patient, catalog: ctx.platform[:catalog],
                                                   matcher: ctx.platform[:matcher], today: today, city_cnpj: CityProfile.current&.cnpj,
                                                   controlled: ctx.controlled, prescriber_contact: ctx.contact)
        when "controlled_notification_record"
          return Content::NotificationRecord.call(input, role: Issuers.role(cbo), catalog: ctx.platform[:catalog])
        else raise ArgumentError, "tipo sem conteúdo: #{kind}"
        end
      result.ok? ? Result.ok(content: result.payload[:content], items: [], category: nil) : result
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
          ClinicalDocument.create!(attrs.merge(verification_token: Codes.token, short_code: Codes.public_short_code))
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

    def record_medication!(document, patient, entry, content, by, now)
      result = Patients::ApplyMedicationEvent.call(
        patient: patient, action: "add", by: by, source: { document: document }, origin: "prescription",
        catalog_item: entry, dosage_summary: content.dig("item", "dosage_instructions"), continuous: false, on_active: :change,
        on: now.in_time_zone.to_date
      )
      result.failure? ? result : nil
    end

    def invalid(field) = Result.fail(:invalid_content, details: { field: field })
    private_class_method :prescription_platform, :issue, :publish!, :build, :replaced, :create!, :medications!, :record_medication!, :invalid
  end
end
