# app/services/signatures/canonical.rb
# JSON canônico da consulta e do adendo (ADR 0032; spec §7; contrato §10): o
# registro estruturado assinado em CAdES (fonte de verdade), na forma EXATA dos
# esquemas da tag clinical-v1.0.0 do contracts (commit ff7df1d), copiados sem
# alteração em config/clinical/consultation-v1.json e
# config/clinical/consultation-addendum-v1.json (mude a cópia só com tag nova;
# o vetor e os exemplos ficam em spec/fixtures/clinical/). Fechados: o que não
# está no esquema não entra. Texto vazio = null; horários UTC com Z; CPF, CNES,
# IBGE e CBO só dígitos; care_type, condutas e height_cm inteiros; todo exame
# com a competência SIGTAP (AAAAMM) gravada no ato. Gerado de documentos
# imutáveis → determinístico (a ordem das chaves é a do RFC 8785).
require "json_schemer"

module Signatures
  module Canonical
    CONSULTATION_SCHEMA = "rotasaude.consultation.v1".freeze
    ADDENDUM_SCHEMA = "rotasaude.consultation_addendum.v1".freeze
    SCHEMA_FILES = { CONSULTATION_SCHEMA => Rails.root.join("config/clinical/consultation-v1.json"),
                     ADDENDUM_SCHEMA => Rails.root.join("config/clinical/consultation-addendum-v1.json") }.freeze

    class Invalid < StandardError; end

    Built = Data.define(:document, :json, :sha256) do
      def inspect = "#<Signatures::Canonical::Built #{sha256}>"
      alias_method :to_s, :inspect
    end

    module_function

    def for(document)
      case document
      when Consultation then consultation(document)
      when ConsultationAddendum then addendum(document)
      else raise ArgumentError, "documento fora do catálogo"
      end
    end

    def consultation(consultation)
      raise Invalid, "not_finalized" unless consultation.finalized?

      own = ->(relation) { relation.where(addendum_id: nil).order(:created_at, :id) }
      body = {
        "id" => consultation.id, "started_at" => time(consultation.started_at),
        "finalized_at" => time(consultation.finalized_at), "care_type" => consultation.care_type,
        "subjective" => text(consultation.subjective), "objective" => text(consultation.objective),
        "assessment" => text(consultation.assessment), "plan" => text(consultation.plan), "vitals" => vitals(consultation),
        "evaluated_problems" => own.call(consultation.problem_items).map do |row|
          problem(row.terminology, row.code, row.terminology_release_id, row.action, row.onset_on, row.onset_precision)
        end,
        "conducts" => own.call(consultation.conducts).pluck(:code),
        "exam_requests" => own.call(consultation.exam_requests).map { |row| exam(row.sigtap_code, row.sigtap_competence, row.cid10_justification) },
        "outcome" => outcome(consultation.attendance)
      }
      built(CONSULTATION_SCHEMA, header(consultation, consultation.author_user)
                                   .merge("schema" => CONSULTATION_SCHEMA, "consultation" => body))
    end

    # O adendo é só da autora da consulta (19a, revisão da leitura; override 6):
    # o CBO do cabeçalho é o da consulta.
    def addendum(addendum, chain: {})
      consultation = addendum.consultation
      body = { "consultation_id" => consultation.id, "id" => addendum.id, "created_at" => time(addendum.created_at),
               "reason" => addendum.reason, "text" => addendum.text, "changes" => changes(addendum.item_changes),
               "previous_sha256" => previous_sha256(addendum, chain: chain) }
      built(ADDENDUM_SCHEMA, header(consultation, addendum.author_user)
                               .merge("schema" => ADDENDUM_SCHEMA, "addendum" => body))
    end

    # Desvio 1 (esquema do contracts): o canonical_sha256 do documento ASSINADO
    # anterior da mesma consulta, na ordem de criação; os já preparados no MESMO
    # lote (chain) contam como assinados (se um falhar, os seguintes da consulta
    # não são assinados — Signing); nenhum → o sha256 do JSON canônico da consulta.
    def previous_sha256(addendum, chain: {})
      consultation = addendum.consultation
      earlier = consultation.addenda
                            .where("(consultation_addenda.created_at, consultation_addenda.id) < (?, ?)", addendum.created_at, addendum.id)
                            .order(created_at: :desc, id: :desc).pluck(:id)
      signed = Signature.where(document_type: "ConsultationAddendum", document_id: earlier).pluck(:document_id, :canonical_sha256).to_h
      earlier.each do |id|
        sha = chain[[ "ConsultationAddendum", id ]] || signed[id]
        return sha if sha
      end

      chain[[ "Consultation", consultation.id ]] ||
        Signature.where(document_type: "Consultation", document_id: consultation.id).pick(:canonical_sha256) ||
        consultation(consultation).sha256
    end

    # A mensagem leva só ponteiros e palavras-chave do esquema, nunca valores.
    def validate!(schema_name, document)
      errors = schema(schema_name).validate(document).first(5)
      return document if errors.empty?

      raise Invalid, "documento fora do esquema #{schema_name}: " \
                     "#{errors.map { |e| "#{e['data_pointer'].presence || '(root)'} #{e['type']}" }.join('; ')}"
    end

    def built(schema_name, document)
      validate!(schema_name, document)
      json = Jcs.dump(document)
      Built.new(document: document, json: json, sha256: Digest::SHA256.hexdigest(json))
    end

    def header(consultation, author)
      profile = CityProfile.current
      unit = consultation.attendance.health_unit
      professional = author.professional
      patient = consultation.patient
      council = professional && { "name" => professional.council, "state" => professional.council_state,
                                  "registration_number" => professional.registration_number }
      { "city" => { "ibge_code" => profile&.ibge_code.presence, "name" => profile&.name.presence || Current.city&.name },
        "unit" => { "cnes" => unit.cnes.presence, "name" => unit.name },
        "professional" => { "name" => professional&.professional_name, "cpf" => professional&.cpf,
                            "cbo_code" => consultation.cbo_code, "council" => council },
        "patient" => { "display_name" => patient.display_name, "cpf" => patient.cpf, "birth_date" => patient.birth_date.presence } }
    end

    # item_changes do adendo (contrato do 19a §9; `changes` é do ActiveModel::Dirty):
    # chave presente = mudou. conducts e exam_requests são as listas FINAIS e
    # saem sempre que a chave existe — exam_requests [] = todos cancelados
    # (override 2). evaluated_problems só é gravado com eventos.
    def changes(stored)
      raw = stored.to_h.stringify_keys
      result = {}
      if raw.key?("evaluated_problems")
        result["evaluated_problems"] = Array(raw["evaluated_problems"]).map do |item|
          problem(item["terminology"], item["code"], item["release_id"], item["action"], item["onset_on"], item["onset_precision"])
        end
      end
      result["conducts"] = Array(raw["conducts"]).map(&:to_i) if raw.key?("conducts")
      if raw.key?("exam_requests")
        result["exam_requests"] = Array(raw["exam_requests"]).map do |item|
          exam(item["sigtap_code"], item["sigtap_competence"], item["cid10_justification"])
        end
      end
      result
    end

    def problem(terminology, code, release_id, action, onset_on, onset_precision)
      { "terminology" => terminology, "code" => code, "label" => ClinicalTerms.label(terminology, code, release_id),
        "release" => release_version(release_id), "action" => action,
        "onset_on" => onset_on.respond_to?(:iso8601) ? onset_on.iso8601 : onset_on.presence,
        "onset_precision" => onset_precision.presence }.compact
    end

    # A competência é a gravada no ato (consultation_exam_requests.sigtap_competence
    # ou item_changes[*].sigtap_competence): o rótulo sai da mesma tabela.
    def exam(code, competence, cid10)
      { "sigtap_code" => code, "competence" => competence, "label" => ClinicalTerms::SigtapExams.label(code, competence),
        "cid10_justification" => cid10.presence }.compact
    end

    # Só as medidas preenchidas; IMC nulo não entra (o esquema recusa null).
    def vitals(consultation)
      Screenings::VitalSigns.json(consultation.vitals).merge("bmi" => Screenings::VitalSigns.bmi(consultation.vitals))
                            .compact.transform_keys(&:to_s)
    end

    def outcome(attendance)
      { "code" => attendance.outcome, "referral_unit_cnes" => attendance.referral_unit&.cnes.presence,
        "referral_note" => text(attendance.referral_note) }.compact
    end

    def release_version(id) = id && TerminologyRelease.where(id: id).pick(:version)
    def text(value) = value.presence
    def time(value) = value&.utc&.iso8601

    # Como Protocols::Validation::Schema: o esquema lido do arquivo copiado.
    def schema(name)
      @schemas ||= {}
      @schemas[name] ||= JSONSchemer.schema(JSON.parse(File.read(SCHEMA_FILES.fetch(name))))
    end
    private_class_method :built, :header, :changes, :problem, :exam, :vitals, :outcome, :release_version, :text, :time, :schema
  end
end
