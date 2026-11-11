# Base das rotas /urgency/* (ADR 0050): sessão do dashboard e `urgency_care`
# utilizável (403 feature_disabled), lido fora da transação da cidade. Dado do
# paciente (CPF, CNS, nome, descrição do não identificado, queixa) só do corpo
# JSON, nunca da URL. O padrão do Tfd::BaseController.
module Urgency
  class BaseController < ApplicationController
    include Authentication
    include MfaStepUp
    include ::UrgencyGate

    wrap_parameters false

    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    # Contrato §14 Q15 (preflight C-20): encontro fechado é encounter_closed
    # (o already_closed é só do 13); patient_not_found é 404; o resto das
    # recusas (not_unidentified inclusive) é 422.
    FAILURE_STATUS = {
      missing_role: :forbidden, missing_link: :forbidden, cbo_not_allowed: :forbidden,
      not_found: :not_found, patient_not_found: :not_found,
      encounter_open: :conflict, encounter_closed: :conflict, already_identified: :conflict, merge_blocked: :conflict,
      bed_label_taken: :conflict, bed_occupied: :conflict, bed_taken: :conflict,
      cpf_taken: :conflict, cns_taken: :conflict, duplicate_suspected: :conflict, citizen_not_verified: :conflict, consultation_in_progress: :conflict,
      not_unidentified: :unprocessable_entity, pain_scale_required: :unprocessable_entity,
      justification_required: :unprocessable_entity,
      # Módulo 32b (§4): a observação.
      not_in_care: :unprocessable_entity, bed_unavailable: :unprocessable_entity, not_in_observation: :unprocessable_entity,
      observation_changed: :conflict, # Q15: a tela viu outra estadia (ou nenhuma)
      prescription_changed: :conflict, # Q16: a tela viu outra versão ativa (ou nenhuma)
      # A prescrição interna (§5): sem a consulta, item fora do catálogo prescritível, versão que não está ativa.
      consultation_required: :unprocessable_entity, catalog_item_invalid: :unprocessable_entity,
      prescription_not_active: :unprocessable_entity,
      # A checagem (§6, Q5, Q6): o horário já checado (em qualquer versão) é conflito; o resto, forma.
      slot_taken: :conflict,
      slot_invalid: :unprocessable_entity, slot_not_due: :unprocessable_entity, max_per_day_reached: :unprocessable_entity,
      stock_deduction_disabled: :unprocessable_entity, lot_invalid: :unprocessable_entity
    }.freeze
    KEY_PATH_MAX = 64

    before_action :require_urgency!

    private

    # `{ error, path? }` e, na recusa de campo (422 com path, P23), `problems`
    # com esse problema (ou os do resultado). O duplicado suspeito (§14 Q23)
    # leva `candidates` (a forma do candidato do 24a) e grava a trilha de cada
    # candidato mostrado.
    def render_failure(result)
      status = FAILURE_STATUS.fetch(result.reason, :unprocessable_entity)
      payload = { error: result.reason.to_s }
      payload[:path] = result.details[:path] if result.details[:path]
      problems = result.details[:problems]
      problems ||= [ { path: payload[:path], error: payload[:error] } ] if payload[:path] && status == :unprocessable_entity
      payload[:problems] = problems if problems
      payload[:candidates] = duplicate_candidates(result.details[:candidate_ids]) if result.details.key?(:candidate_ids)
      render json: payload, status: status
    end

    def duplicate_candidates(ids)
      ids.each { |id| Trail.viewed!(user: Current.user, patient_id: id, resource: "patient_duplicates") }
      Json.duplicate_candidates(ids)
    end

    # 422 no formato uniforme: `error`/`path` no topo e `problems` com esse problema.
    def render_refusal(path, error = "invalid_request")
      render json: { error: error.to_s, path: path, problems: [ { path: path, error: error.to_s } ] }, status: :unprocessable_entity
    end

    # Detalhe do encontro (§14 Q6, Q19) em `{ encounter, **extra }`: com
    # `clinical: false` (sem acesso clínico) sem o clínico. Todo detalhe com
    # campo clínico ou com a descrição do provisório grava a trilha
    # (resource encounter).
    def render_encounter(encounter, clinical:, status: :ok, **extra)
      catalog = clinical ? Pharmacy::Json.catalog_for(Json.catalog_ids(encounter)) : {}
      json = Json.encounter(encounter, clinical: clinical, catalog: catalog)
      patient = encounter.patient
      Trail.viewed!(user: Current.user, patient_id: patient.id, resource: "encounter") if clinical || json[:patient].key?(:description)
      render json: { encounter: json, **extra }, status: status
    end

    # O encontro do id da URL (malformado ou inexistente → 404). Renderiza e
    # devolve nil quando não acha.
    def find_encounter(id)
      encounter = uuid?(id) ? UrgencyEncounter.includes(:attendance).find_by(id: id) : nil
      not_found unless encounter
      encounter
    end

    def forbid(reason = "missing_role") = render(json: { error: reason }, status: :forbidden)
    def not_found = render(json: { error: "not_found" }, status: :not_found)
    def uuid?(value) = value.is_a?(String) && value.match?(UUID)

    # Recepção da UPA (contrato §1): sem citizen_verifier → 403 missing_role.
    # Renderiza e devolve false quando recusa.
    def require_reception!
      return true if Access.reception?(Current.user)

      forbid
      false
    end

    # Dado do paciente e texto livre só do corpo JSON: na query vale como ausente.
    def body_param(key) = request.request_parameters[key]
    def body = request.request_parameters.except("controller", "action", "id")

    # Chave do corpo fora de `allowed` → 422 invalid_request com o nome da
    # chave (truncado). Renderiza e devolve false quando recusa.
    def only_keys!(allowed)
      unknown = (body.keys - allowed).first
      return true unless unknown

      render_refusal(unknown.to_s[0, KEY_PATH_MAX])
      false
    end

    # Rotas cujo dado sensível só vem no corpo: query com chave fora de
    # `allowed` → 422 invalid_request com o path (só o NOME da chave, truncado).
    def query_only!(*allowed)
      unknown = (request.query_parameters.keys - allowed.map(&:to_s)).first
      return true unless unknown

      render_refusal(unknown.to_s[0, KEY_PATH_MAX])
      false
    end
  end
end
