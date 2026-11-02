# Bundle FHIR R4 (document) do RIA-R 2.0: Composition primeiro, Immunization
# referenciada na seção (módulo 29, Desvios 14 e 15). Nenhuma tradução de código:
# dose, estratégia e imunobiológico vão com o código do catálogo (a estratégia já
# é o código RNDS); via, local e grupo, com o `rnds_code` das terminologias. O
# código do fabricante vem do catálogo na hora de montar, pela `manufacturer_key`
# do lote (V19); código nulo = sem o fabricante. O cancelamento (V7) é um Bundle
# substituto: `relatesTo.replaces` com o rnds_id do original e
# `Immunization.status = entered-in-error` (a confirmar na homologação).
#
# O resultado é dado sensível (CPF, CNS, vacina): vai só para o cifrado do
# RndsOutboxEntry#payload, nunca para log, evento, erro nem inspect.
module Rnds
  module Bundle
    KINDS = %w[application cancellation].freeze
    NAMESPACE = "6ba7b810-9dad-11d1-80b4-00c04fd430c8".freeze
    DEFAULT_MATERNAL_CONDITION = "1" # "Nenhuma": só na aplicação, quando a condição não foi registrada

    module_function

    # `cnes`: o CNES solicitante da credencial (`requester_cnes`) = custodiante.
    # O executante (`performer[0]`) é o CNES da unidade da dose (o mesmo que a
    # NT 115 confere no Rnds::Validation); na transcrição a dose foi aplicada
    # fora, a unidade que transcreveu não é a executante e o esqueleto exige o
    # campo (1..1): cai no solicitante (gate de homologação).
    # -> Hash (chaves String)
    def build(immunization:, kind:, cnes:, now:, original_rnds_id: nil)
      raise ArgumentError, "unknown rnds bundle kind" unless KINDS.include?(kind)
      raise ArgumentError, "cancellation needs the original rnds_id" if kind == "cancellation" && original_rnds_id.blank?

      profile = Profile.current
      urls = { bundle: urn(immunization, kind, "bundle"), composition: urn(immunization, kind, "composition"),
               immunization: urn(immunization, kind, "immunization") }
      resource = immunization_resource(immunization, kind, performer_cnes(immunization, cnes), profile)
      composition = composition_resource(immunization, kind, cnes, now, original_rnds_id, urls[:immunization], profile)
      { "resourceType" => "Bundle",
        "identifier" => { "system" => profile.identifiers[:bundle], "value" => urls[:bundle].delete_prefix("urn:uuid:") },
        "type" => "document", "timestamp" => now.in_time_zone.iso8601,
        "entry" => [ { "fullUrl" => urls[:composition], "resource" => composition },
                     { "fullUrl" => urls[:immunization], "resource" => resource } ] }
    end

    def composition_resource(imm, kind, cnes, now, original_rnds_id, immunization_url, profile)
      composition = { "resourceType" => "Composition", "meta" => { "profile" => [ profile.composition_profile ] },
                      "status" => "final",
                      "type" => { "coding" => [ { "system" => profile.code_systems[:document_type], "code" => profile.document_type_code } ] },
                      "subject" => { "identifier" => patient_identifier(imm.patient, profile) },
                      "date" => now.in_time_zone.iso8601,
                      "author" => [ { "identifier" => practitioner_identifier(imm, profile) } ],
                      "title" => "Registro de Imunobiológico Administrado",
                      "custodian" => { "identifier" => facility_identifier(cnes, profile) },
                      "section" => [ { "title" => "Imunobiológico administrado", "entry" => [ { "reference" => immunization_url } ] } ] }
      if kind == "cancellation"
        composition["relatesTo"] = [ { "code" => "replaces", "targetIdentifier" => { "value" => original_rnds_id } } ]
      end
      composition
    end

    def immunization_resource(imm, kind, cnes, profile)
      systems = profile.code_systems
      resource = { "resourceType" => "Immunization", "meta" => { "profile" => [ profile.immunization_profile ] },
                   "status" => kind == "cancellation" ? "entered-in-error" : "completed",
                   "vaccineCode" => { "coding" => [ coding(systems[:immunobiological], imm.immunobiological_code) ] },
                   "subject" => { "identifier" => patient_identifier(imm.patient, profile) },
                   "occurrenceDateTime" => imm.applied_at.in_time_zone.iso8601,
                   "recorded" => imm.created_at.in_time_zone.iso8601,
                   "primarySource" => !imm.transcription,
                   "performer" => [ { "actor" => { "identifier" => facility_identifier(cnes, profile) } },
                                    { "actor" => { "identifier" => practitioner_identifier(imm, profile) } } ],
                   "extension" => extensions(imm, profile) }
      lot = lot_number(imm)
      resource["lotNumber"] = lot if lot.present?
      manufacturer = manufacturer_code(imm)
      resource["manufacturer"] = { "identifier" => { "system" => systems[:manufacturer], "value" => manufacturer } } if manufacturer.present?
      add_coding(resource, "route", systems[:route], Vaccination::Terminologies.rnds_code("route", imm.route), imm.route)
      add_coding(resource, "site", systems[:site], Vaccination::Terminologies.rnds_code("site", imm.site), imm.site)
      resource
    end

    def extensions(imm, profile)
      list = [ coding_extension(profile.extensions[:strategy], profile.code_systems[:strategy], Vaccination::Terminologies.rnds_code("strategy", imm.strategy)),
               # O código da dose é um enum (9 = Única, 6 = 1º reforço): vai como coding no CodeSystem, nunca como ordinal.
               coding_extension(profile.extensions[:dose], profile.code_systems[:dose], Vaccination::Terminologies.rnds_code("dose", imm.dose_code)),
               { "url" => profile.extensions[:transcription], "valueBoolean" => imm.transcription } ]
      condition = maternal_condition(imm)
      if condition
        list.insert(2, coding_extension(profile.extensions[:maternal_condition], profile.code_systems[:maternal_condition],
                                        Vaccination::Terminologies.rnds_code("maternal_condition", condition)))
      end
      if imm.care_group.present?
        list.insert(1, coding_extension(profile.extensions[:care_group], profile.code_systems[:care_group],
                                        Vaccination::Terminologies.rnds_code("care_group", imm.care_group)))
      end
      list
    end

    # Aplicação: nulo vira "Nenhuma" (campo 1..1). Transcrição: nulo não se afirma (ninguém registrou).
    def maternal_condition(imm) = imm.maternal_condition.presence || (DEFAULT_MATERNAL_CONDITION unless imm.transcription)

    def coding_extension(url, system, code) = { "url" => url, "valueCoding" => coding(system, code) }
    def coding(system, code) = { "system" => system, "code" => code.to_s }

    def add_coding(resource, key, system, rnds_code, raw)
      return if raw.blank?

      resource[key] = { "coding" => [ coding(system, rnds_code || raw) ] }
    end

    # Aplicação: o lote do estoque; transcrição: o texto da caderneta, se houver.
    def lot_number(imm) = imm.stock_lot&.lot_number || imm.lot_number_text

    # V19: o lote guarda só a chave; o código sai do catálogo agora.
    def manufacturer_code(imm)
      key = imm.stock_lot&.manufacturer_key
      return if key.blank?

      Vaccination::Immunobiologicals.find(imm.immunobiological_code)&.manufacturer(key)&.code.presence
    end

    # CPF quando há; senão o CNS (a portaria pede um dos dois).
    def patient_identifier(patient, profile)
      return { "system" => profile.identifiers[:cpf], "value" => patient.cpf } if patient.cpf.present?

      { "system" => profile.identifiers[:cns], "value" => patient.cns }
    end

    def practitioner_identifier(imm, profile)
      { "system" => profile.identifiers[:practitioner_cns], "value" => imm.vaccinator_user.professional&.cns }
    end

    def performer_cnes(imm, requester_cnes)
      return requester_cnes if imm.transcription

      imm.health_unit&.cnes.presence || requester_cnes
    end

    def facility_identifier(cnes, profile) = { "system" => profile.identifiers[:cnes], "value" => cnes }

    # UUID estável por dose e tipo: o mesmo Bundle remontado tem os mesmos ids.
    def urn(imm, kind, part) = "urn:uuid:#{Digest::UUID.uuid_v5(NAMESPACE, "#{imm.id}/#{kind}/#{part}")}"

    private_class_method :composition_resource, :immunization_resource, :extensions, :maternal_condition, :coding_extension, :coding, :add_coding,
                         :lot_number, :manufacturer_code, :performer_cnes, :patient_identifier, :practitioner_identifier, :facility_identifier, :urn
  end
end
