module Regulation
  # Documento RIRA 1.0.0 (Bundle `document`) de um pedido de regulação
  # (módulo 26c; Valores 7 e 9; Q6, Q15, Q18; pré-voo I6, I9). Puro sobre os
  # fatos (`RiraFacts`): nenhuma leitura de banco aqui, e o `build` nunca
  # levanta por fato ausente — o campo some e o `RiraSkeleton`/a
  # `RndsValidation` acusam. Canônicos e sistemas só do `RiraProfile`
  # (config/rnds/rira_1_0.yml).
  #
  # Quatro entradas, nesta ordem: Composition (`BRRegulacaoAssistencial`),
  # Appointment, ServiceRequest e Condition, cada uma com o seu `meta.profile`
  # e um `fullUrl` `urn:uuid` novo a cada montagem. A situação (`status`) é um
  # `RndsStatus::Target`, um passo `{ "status", "at" }` ou só o código (o
  # instante vem de `facts.status_times`).
  #
  # O resultado é dado sensível (CPF, CNS, CID): vai só para o corpo da remessa
  # e para o payload cifrado, nunca para log, evento, erro nem inspect.
  module RiraBundle
    TITLE = "Regulação Assistencial".freeze
    DOCUMENT_TYPE = "RA".freeze
    PARTICIPANT_TYPE = "PCT".freeze
    PARTICIPANT_STATUS = "accepted".freeze
    CLINICAL_STATUS = "active".freeze
    INTENT = "proposal".freeze
    # O executante vai em `ServiceRequest.performer` só nestas situações
    # (Valor 7; na falta, Q22).
    PERFORMER_STATUSES = %w[booked attended absence].freeze
    # `Appointment.start`/`end` (decisão 18, Q20): o horário nestas situações;
    # `ServiceRequest.occurrenceDateTime` (Q21), a data da realização.
    DATED_STATUSES = %w[booked attended absence].freeze
    OCCURRENCE_STATUSES = %w[attended absence].freeze

    module_function

    # O atalho do contrato (§3): lê os fatos e monta.
    def for(request:, sync:, status:, now:, settings: RegulationRndsSetting.current,
            credential: IntegrationCredential.find_by(kind: "rnds_regulation"))
      build(facts: RiraFacts.for(request: request, settings: settings, credential: credential), sync: sync, status: status, now: now)
    end

    # -> Hash (chaves String). `sync` responde `bundle_identifier` e `last_rnds_id`.
    def build(facts:, sync:, status:, now:)
      code, at = situation(status, facts)
      appointment_status, request_status = RndsCatalog::STATUS_RELATION.fetch(code)
      profile = RiraProfile.current
      urls = Array.new(4) { "urn:uuid:#{SecureRandom.uuid}" }
      patient = { "system" => profile.identifiers[:individual], "value" => facts.patient_cpf || facts.patient_cns }
      slot = slot_for(facts, code, at)

      resources = [
        composition(facts, code, at, sync, now, patient, urls, profile),
        appointment(facts, appointment_status, patient, urls, profile),
        service_request(facts, request_status, slot, patient, urls, profile),
        condition(facts, patient, profile)
      ]
      place_dates!(resources, profile, scheduled_at: slot&.starts_at, requested_at: facts.requested_at,
                                       authorized_at: facts.authorized_at)
      resources[1]["end"] = time(slot&.ends_at)
      resources[2]["occurrenceDateTime"] = time(slot.starts_at) if slot && OCCURRENCE_STATUSES.include?(code)
      prune({ "resourceType" => "Bundle",
              "identifier" => { "system" => (profile.identifiers[:requester_prefix] + facts.requester_id if facts.requester_id),
                                "value" => sync.bundle_identifier },
              "type" => "document", "timestamp" => time(now),
              "entry" => urls.zip(resources).map { |url, resource| { "fullUrl" => url, "resource" => resource } } })
    end

    # Impressão digital (Valor 9): SHA-256 hex do JSON de chaves ordenadas, sem
    # o que muda a cada montagem ou remessa (`timestamp`, `identifier`,
    # `fullUrl`, as referências `urn:uuid` — trocadas pela posição —,
    # `Composition.date`, `Composition.author` e `Composition.relatesTo`).
    def digest(bundle)
      doc = JSON.parse(JSON.generate(bundle))
      doc.delete("timestamp")
      doc.delete("identifier")
      positions = {}
      Array(doc["entry"]).each_with_index { |entry, index| positions[entry.delete("fullUrl")] = "entry/#{index}" }
      doc = positional(doc, positions)
      Array(doc["entry"]).map { |entry| entry["resource"] }.select { |r| r.is_a?(Hash) && r["resourceType"] == "Composition" }
                         .each { |composition| composition.except!("date", "author", "relatesTo") }
      Digest::SHA256.hexdigest(JSON.generate(sorted(doc)))
    end

    def composition(facts, code, at, sync, now, patient, urls, profile)
      systems = profile.code_systems
      composition = {
        "resourceType" => "Composition", "meta" => meta(profile.profiles[:composition]), "status" => "final",
        "type" => { "coding" => [ coding(systems[:document_type], DOCUMENT_TYPE) ] },
        "category" => [ { "coding" => [ coding(systems[:modality], RndsLimits::MODALITY) ] } ],
        "subject" => { "identifier" => patient },
        # date-1 do perfil: só a data (AAAA-MM-DD).
        "date" => now.in_time_zone.to_date.iso8601,
        "author" => [ { "identifier" => establishment(facts.author_cnes, profile) } ],
        "title" => TITLE
      }
      if sync.last_rnds_id.present?
        composition["relatesTo"] = [ { "code" => "replaces", "targetReference" => { "reference" => "Composition/#{sync.last_rnds_id}" } } ]
      end
      composition.merge(
        "event" => [ { "code" => [ { "coding" => [ coding(systems[:status], code) ] } ], "period" => { "end" => time(at) } } ],
        "section" => [ { "entry" => [ { "reference" => urls[1] } ] } ]
      )
    end

    def appointment(facts, status, patient, urls, profile)
      systems = profile.code_systems
      {
        "resourceType" => "Appointment", "meta" => meta(profile.profiles[:appointment]), "status" => status,
        "serviceCategory" => [ { "coding" => [ coding(systems[:modality], RndsLimits::MODALITY) ] } ],
        "serviceType" => [ { "coding" => [ coding(systems[:sigtap], facts.sigtap) ] } ],
        "specialty" => (facts.performer_cbo ? [ { "coding" => [ coding(systems[:cbo], facts.performer_cbo) ] } ] : nil),
        "appointmentType" => (facts.priority ? { "coding" => [ coding(profile.priority_system, facts.priority) ] } : nil),
        "reasonReference" => [ { "reference" => urls[3] } ],
        "basedOn" => [ { "reference" => urls[2] } ],
        "participant" => [ { "type" => [ { "coding" => [ coding(systems[:participant_type], PARTICIPANT_TYPE) ] } ],
                             "actor" => { "identifier" => patient }, "status" => PARTICIPANT_STATUS } ]
      }
    end

    def service_request(facts, status, slot, patient, urls, profile)
      systems = profile.code_systems
      {
        "resourceType" => "ServiceRequest", "meta" => meta(profile.profiles[:service_request]), "status" => status,
        "intent" => INTENT,
        "category" => [ { "coding" => [ coding(systems[:modality], RndsLimits::MODALITY) ] } ],
        "priority" => facts.priority,
        "code" => { "coding" => [ coding(systems[:sigtap], facts.sigtap) ] },
        "subject" => { "identifier" => patient },
        "requester" => { "identifier" => establishment(facts.requester_cnes, profile) },
        "performerType" => (facts.performer_cbo ? { "coding" => [ coding(systems[:cbo], facts.performer_cbo) ] } : nil),
        "performer" => (slot ? [ { "identifier" => establishment(slot.cnes, profile) } ] : nil),
        "reasonReference" => [ { "reference" => urls[3] } ]
      }
    end

    # CID-10 tem precedência sobre o CIAP-2.
    def condition(facts, patient, profile)
      systems = profile.code_systems
      diagnosis = if facts.cid10 then coding(systems[:cid10], facts.cid10)
                  elsif facts.ciap2 then coding(systems[:ciap2], facts.ciap2)
                  end
      {
        "resourceType" => "Condition", "meta" => meta(profile.profiles[:condition]),
        "clinicalStatus" => { "coding" => [ coding(systems[:condition_clinical], CLINICAL_STATUS) ] },
        "code" => (diagnosis ? { "coding" => [ diagnosis ] } : nil),
        "subject" => { "identifier" => patient }
      }
    end

    # As datas vão nos campos do `date_fields` do perfil (decisão 18).
    def place_dates!(resources, profile, values)
      values.each do |fact, value|
        type, field = profile.date_fields.fetch(fact).split(".", 2)
        resources.find { |resource| resource["resourceType"] == type }[field] = time(value)
      end
    end

    # O horário do documento (datas e CNES do executante), ou nil:
    # `booked`/`attended` → o horário do pedido (Q20, Q21); `absence` → o
    # horário da última linha `missed` até o instante da falta (Q18, Q22, Q24).
    # A rede é a do horário faltado, não a da autorização vigente; sem horário
    # até a falta, nil (falta externa de antes da Q24: o esqueleto e a
    # conferência barram).
    def slot_for(facts, code, at)
      return nil unless DATED_STATUSES.include?(code)
      return absence_slot(facts, at) if code == RndsStatus::ABSENCE
      return nil unless facts.scheduled_at

      RiraFacts::Slot.new(starts_at: facts.scheduled_at, ends_at: facts.scheduled_ends_at, cnes: facts.performer_cnes)
    end

    def absence_slot(facts, at)
      return nil unless at

      limit = at.floor(6)
      Array(facts.absences).select { |slot| slot.missed_at.floor(6) <= limit }.max_by(&:missed_at)
    end

    # [código, instante] da situação: Target, passo { status, at } ou só o código.
    def situation(status, facts)
      code, at =
        if status.respond_to?(:status) then [ status.status, status.at ]
        elsif status.is_a?(Hash) then [ status["status"] || status[:status], status["at"] || status[:at] ]
        else [ status.to_s, (facts.status_times || {})[status.to_s] ]
        end
      [ code, at.is_a?(String) ? Time.zone.parse(at) : at ]
    end

    def meta(profile_url) = { "profile" => [ profile_url ] }
    def coding(system, code) = { "system" => system, "code" => code }
    def establishment(cnes, profile) = { "system" => profile.identifiers[:establishment], "value" => cnes }
    def time(value) = value&.in_time_zone&.iso8601

    # Sem nulos, textos vazios, objetos nem listas vazias.
    def prune(value)
      case value
      when Hash then value.each_with_object({}) { |(key, v), out| v = prune(v); out[key] = v unless blank?(v) }
      when Array then value.map { |v| prune(v) }.reject { |v| blank?(v) }
      else value
      end
    end

    def blank?(value) = value.nil? || value == "" || ((value.is_a?(Hash) || value.is_a?(Array)) && value.empty?)

    def positional(value, positions)
      case value
      when Hash then value.to_h { |key, v| [ key, key == "reference" && positions.key?(v) ? positions[v] : positional(v, positions) ] }
      when Array then value.map { |v| positional(v, positions) }
      else value
      end
    end

    def sorted(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [ key, sorted(value[key]) ] }
      when Array then value.map { |v| sorted(v) }
      else value
      end
    end

    private_class_method :composition, :appointment, :service_request, :condition, :place_dates!, :slot_for,
                         :meta, :coding, :establishment, :time, :prune, :blank?, :positional, :sorted
  end
end
