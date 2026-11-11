# Base das rotas /ombudsman/* (ADR 0051): sessão do dashboard e `ombudsman`
# utilizável (403 feature_disabled). Texto da manifestação, nome, CPF, contato
# e justificativa só do corpo JSON, nunca da URL. O padrão do
# Psychosocial::BaseController. Nenhuma ação do módulo pede step-up (U4): a
# justificativa e a trilha por abertura são o controle.
module Ombudsman
  class BaseController < ApplicationController
    include Authentication
    include MfaStepUp
    include ::OmbudsmanGate

    wrap_parameters false

    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    # Conflitos 409; papel e dono 403; inexistente 404; link vencido 410;
    # limites 429 (Q43: `too_many_requests`; o teto da cidade é
    # `daily_cap_reached`); o resto das recusas é 422.
    FAILURE_STATUS = {
      manifestation_changed: :conflict, forwarding_changed: :conflict, already_answered: :conflict, reopen_pending: :conflict,
      already_decided: :conflict, report_published: :conflict, already_published: :conflict,
      missing_role: :forbidden, not_own_citizen: :forbidden,
      not_found: :not_found,
      link_expired: :gone,
      too_many_requests: :too_many_requests, daily_cap_reached: :too_many_requests
    }.freeze
    KEY_PATH_MAX = 64

    before_action :require_ombudsman!

    private

    # `{ error, path?, problems? }`: só quando o resultado traz.
    def render_failure(result)
      payload = { error: result.reason.to_s }
      %i[path problems].each { |key| payload[key] = result.details[key] if result.details[key] }
      render json: payload, status: FAILURE_STATUS.fetch(result.reason, :unprocessable_entity)
    end

    # 422 no formato uniforme: `error`/`path` no topo e `problems` com esse problema.
    def render_refusal(path, error = "invalid_request")
      render json: { error: error.to_s, path: path, problems: [ { error: error.to_s, path: path } ] }, status: :unprocessable_entity
    end

    def forbid(reason = "missing_role") = render(json: { error: reason }, status: :forbidden)
    def not_found = render(json: { error: "not_found" }, status: :not_found)
    def uuid?(value) = value.is_a?(String) && value.match?(UUID)

    # Texto e dado de pessoa só do corpo JSON: na query vale como ausente.
    def body_param(key) = request.request_parameters[key]
    def body = request.request_parameters.except("controller", "action", "id")

    # Rotas cujo dado sensível só vem no corpo: query com chave fora de
    # `allowed` → 422 invalid_request com o path (só o NOME da chave, truncado).
    def query_only!(*allowed)
      unknown = (request.query_parameters.keys - allowed.map(&:to_s)).first
      return true unless unknown

      render_refusal(unknown.to_s[0, KEY_PATH_MAX])
      false
    end

    # Técnico ou ouvidor (contrato §1); o respondente que não tem também o
    # papel de técnico não lê nenhuma rota do §5. Renderiza 403 e devolve false.
    def require_staff!
      return true if Access.staff?(Current.user)

      forbid
      false
    end

    # Só o ouvidor (identidade, arquivar, reabrir, configuração...).
    def require_ombudsman_role!
      return true if Access.ombudsman?(Current.user)

      forbid
      false
    end

    # Manifestação da URL (`@manifestation`) para o detalhe e as rotas só de
    # leitura: sem uuid ou inexistente → 404; sem nada na query. Renderiza (e
    # devolve false) quando recusa. As ações que gravam travam pelo
    # Ombudsman::Lock dentro da transação do comando.
    def load_manifestation
      return false unless query_only!

      @manifestation = uuid?(params[:id]) ? OmbudsmanManifestation.find_by(id: params[:id]) : nil
      return true if @manifestation

      not_found
      false
    end
  end
end
