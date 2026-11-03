# Laudo de TFD do médico (contrato §6; §14 T8; plano, Desvio 10): cria o
# processo em `draft` (tfd_case: nil) ou substitui o rascunho/devolvido por
# inteiro (como o SaveDraft do 26a). Autor: Membership health_professional e
# vínculo ativo CBO 225*; o CBO gravado em `requester_cbo` é o da consulta
# (quando `consultation_id`) ou o do vínculo 225* ativo mais antigo. O laudo
# nasce de uma consulta do autor (não descartada) ou de um pedido de regulação
# promovido, sempre do mesmo paciente — ao menos um (`invalid_request` com
# `path: "consultation_id"`). Recusas de forma todas de uma vez em
# `problems[]`; o CID passa pelo normalizador (`invalid_cid10`); as regras do
# envio (distância, atenção básica…) são do Tfd::SubmitCase. O laudo é
# gravado normalizado e cifrado; nunca vai para log, evento nem Result de
# recusa. Evento tfd.case_created (só ids) e a linha `created` do andamento.
module Tfd
  module SaveCase
    KEYS = %w[patient_id consultation_id regulation_request_id report destination_id provider_id].freeze
    REPORT_KEYS = %w[sigtap_code cid10 justification companion_indicated companion_reason transport_mode].freeze
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    EDITABLE = %w[draft returned].freeze
    KEY_PATH_MAX = 64

    module_function

    # Processo de outro autor → not_found (registro de outro escopo por id → 404,
    # como o read). No PATCH o paciente não muda (invalid_request patient_id).
    # -> Result.ok(tfd_case:) | fail(:missing_role | :cbo_not_allowed | :not_found | :invalid_transition |
    #    :invalid_request | :invalid_cid10, path:, problems:)
    def call(attrs:, by:, tfd_case: nil)
      return Result.fail(:missing_role) unless by&.has_role?("health_professional")

      physician_cbo = Access.physician_cbo(by)
      return Result.fail(:cbo_not_allowed) unless physician_cbo

      TfdCase.transaction(requires_new: true) do
        if tfd_case
          tfd_case.lock!
          next Result.fail(:not_found) unless tfd_case.requester_user_id == by.id
          next Result.fail(:invalid_transition) unless EDITABLE.include?(tfd_case.status)
        end

        checked = check(attrs, by, tfd_case)
        next checked if checked.is_a?(Result)

        cbo = checked[:consultation]&.cbo_code || physician_cbo
        next Result.fail(:cbo_not_allowed) unless cbo.start_with?(Catalog::PHYSICIAN_PREFIX)

        Result.ok(tfd_case: persist(tfd_case, checked, cbo, by))
      end
    end

    # -> Hash com os registros e o laudo normalizado | Result (recusa).
    def check(attrs, by, tfd_case)
      return Transport::Support.refuse([ "body" ]) unless attrs.respond_to?(:to_h) && !attrs.is_a?(Array)

      hash = attrs.to_h.stringify_keys
      problems = (hash.keys - KEYS).map { |key| invalid(key.to_s[0, KEY_PATH_MAX]) }
      patient = record(Patient.all, hash["patient_id"])
      problems << invalid("patient_id") unless patient && (tfd_case.nil? || patient.id == tfd_case.patient_id)
      consultation, regulation = origins(hash, by, patient, problems)
      destination = record(TransportDestination.where(active: true), hash["destination_id"])
      problems << invalid("destination_id") unless destination
      provider = nil
      unless hash["provider_id"].nil?
        provider = record(CareProvider.active_providers.where.not(kind: "own"), hash["provider_id"])
        problems << invalid("provider_id") unless provider
      end
      report = report(hash["report"], problems)
      return Transport::Support.failure(problems) if problems.any?

      { patient: patient, consultation: consultation, regulation_request: regulation, transport_destination: destination,
        care_provider: provider, report: report }
    end

    # A consulta (do autor, não descartada) e/ou o pedido de regulação
    # (promovido), do mesmo paciente; ao menos um.
    def origins(hash, by, patient, problems)
      consultation_id = hash["consultation_id"]
      regulation_id = hash["regulation_request_id"]
      consultation = regulation = nil
      unless consultation_id.nil?
        consultation = record(Consultation.where.not(status: "discarded").where(author_user_id: by.id), consultation_id)
        consultation = nil if consultation && patient && consultation.patient_id != patient.id
        problems << invalid("consultation_id") unless consultation
      end
      unless regulation_id.nil?
        regulation = record(RegulationRequest.where.not(status: "draft"), regulation_id)
        regulation = nil if regulation && patient && regulation.patient_id != patient.id
        problems << invalid("regulation_request_id") unless regulation
      end
      problems << invalid("consultation_id") if consultation_id.nil? && regulation_id.nil?
      [ consultation, regulation ]
    end

    # O laudo normalizado (sem ponto no CID, texto sem espaço nas pontas) ou
    # nil, com os problemas acrescentados. Rascunho pode ir incompleto
    # (sigtap_code, cid10 e justification nulos): o envio é que exige.
    def report(raw, problems)
      unless raw.respond_to?(:to_h) && !raw.is_a?(Array)
        problems << invalid("report")
        return nil
      end

      hash = raw.to_h.stringify_keys
      problems.concat((hash.keys - REPORT_KEYS).map { |key| invalid("report.#{key.to_s[0, KEY_PATH_MAX]}") })
      code = hash["sigtap_code"]
      problems << invalid("report.sigtap_code") unless code.nil? || (code.is_a?(String) && code.match?(Rules::SIGTAP))
      cid = Rules.cid10(hash["cid10"])
      problems << { path: "report.cid10", error: "invalid_cid10" } if cid == :invalid
      justification = optional_text(hash["justification"], 1..Catalog::JUSTIFICATION.max)
      problems << invalid("report.justification") if justification == :invalid
      indicated = hash["companion_indicated"]
      problems << invalid("report.companion_indicated") unless Transport::Support.boolean?(indicated)
      reason = optional_text(hash["companion_reason"], Catalog::REASON)
      problems << invalid("report.companion_reason") if reason == :invalid
      mode = hash["transport_mode"]
      problems << invalid("report.transport_mode") unless Catalog::TRANSPORT_MODES.include?(mode)

      { "sigtap_code" => code, "cid10" => (cid unless cid == :invalid), "justification" => (justification unless justification == :invalid),
        "companion_indicated" => indicated, "companion_reason" => (reason unless reason == :invalid), "transport_mode" => mode }
    end

    # nil/"" → nil; texto (sem as pontas) no intervalo; senão :invalid.
    def optional_text(value, range)
      return nil if value.nil?
      return :invalid unless value.is_a?(String)

      text = value.strip
      return nil if text.empty?

      range.cover?(text.length) ? text : :invalid
    end

    def persist(tfd_case, checked, cbo, by)
      fields = checked.merge(requester_cbo: cbo)
      if tfd_case
        tfd_case.update!(fields.merge(version: tfd_case.version + 1))
        return tfd_case
      end

      created = TfdCase.create!(fields.merge(requester_user: by, status: "draft"))
      TfdCaseEvent.create!(tfd_case: created, kind: "created", by_user: by)
      DomainEvents.publish("tfd.case_created", tfd_case_id: created.id, user_id: by.id)
      created
    end

    def record(scope, id) = id.is_a?(String) && id.match?(UUID) ? scope.find_by(id: id) : nil
    def invalid(path) = { path: path, error: "invalid_request" }
    private_class_method :check, :origins, :report, :optional_text, :persist, :record, :invalid
  end
end
