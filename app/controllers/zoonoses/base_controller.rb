# Base das rotas /zoonoses/* (módulo 35b, ADR 0054; contrato §10, §16; plano,
# Valor fixado 4): sessão do dashboard e `zoonoses` utilizável (403
# feature_disabled; o interruptor é lido aqui, fora da transação da cidade).
# Escrita e dado de pessoa (CPF, CNS, microchip) só pelo corpo JSON: a query
# de uma rota que grava ou busca pelo corpo é recusada com 422
# invalid_request, nada lido da URL. Recusas `{ error, path? }` e nada mais:
# nunca nome, CPF, CNS, microchip, telefone ou endereço de pessoa.
module Zoonoses
  class BaseController < ApplicationController
    include Authentication
    include MfaStepUp
    include ::ZoonosesGate
    include ::FieldListQuery

    wrap_parameters false

    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    # O resto das recusas é 422 (inclusive expected_version_required,
    # date_out_of_range e household_not_in_survey, com path, Q20).
    # invalid_transition sempre com path status (Desvio 4). animal_not_active:
    # o animal transferred ou deceased não se edita, nem morre de novo (Q31).
    # person_not_found / citizen_not_verified: as recusas da busca de pessoa
    # dos outros módulos (Patients::LookupByIdentifier).
    FAILURE_STATUS = {
      mfa_required: :unauthorized,
      feature_disabled: :forbidden, missing_role: :forbidden, veterinarian_required: :forbidden, out_of_scope: :forbidden,
      cbo_not_allowed: :forbidden,
      not_found: :not_found, person_not_found: :not_found,
      animal_changed: :conflict, collar_changed: :conflict, campaign_changed: :conflict, survey_changed: :conflict, campaign_already_open: :conflict,
      invalid_transition: :conflict, demand_changed: :conflict, forwarding_changed: :conflict, observation_changed: :conflict,
      test_changed: :conflict, stay_changed: :conflict, stay_already_open: :conflict, already_euthanized: :conflict,
      parameters_changed: :conflict, reserved_subject: :conflict, animal_not_active: :conflict, citizen_not_verified: :conflict
    }.freeze

    before_action :require_zoonoses!

    private

    # feature_disabled de um pré-requisito lido pelo comando (o gate de campo)
    # leva o `feature`, como o require_zoonoses!.
    def render_failure(result)
      render_refusal(result.reason, path: result.details[:path], feature: result.details[:feature])
    end

    def render_refusal(error, path: nil, feature: nil)
      payload = { error: error.to_s }
      payload[:path] = path if path
      payload[:feature] = feature if feature
      render json: payload, status: FAILURE_STATUS.fetch(error.to_sym, :unprocessable_entity)
    end

    def forbid(reason = "missing_role") = render_refusal(reason)
    def not_found = render_refusal("not_found")

    def uuid?(value) = value.is_a?(String) && value.match?(UUID)

    def body_param(key) = request.request_parameters[key]
    def body = request.request_parameters.except("controller", "action", "id")

    # Query com chave fora de `allowed` → 422 invalid_request, nada lido da URL.
    def query_only!(*allowed)
      return true if (request.query_parameters.keys - allowed.map(&:to_s)).empty?

      render_refusal("invalid_request")
      false
    end

    # team? (zoonoses_team, a coordenação; a veterinária precisa do papel,
    # Q12/Q30); senão 403 missing_role (false).
    def team!
      return true if Access.team?(Current.user)

      forbid
      false
    end

    # reader? (team? ou municipal_admin); senão 403 missing_role (false).
    def reader!
      return true if Access.reader?(Current.user)

      forbid
      false
    end

    # coordinator? (endemic_coordinator, a coordenação de vigilância
    # ambiental, Q1); senão 403 missing_role (false).
    def coordinator!
      return true if Access.coordinator?(Current.user)

      forbid
      false
    end

    # Página `{ items, next_before }` de `scope` (mais recente primeiro por
    # `column`, id), com o cursor opaco CareLines::Cursor: `limit + 1` linhas
    # para saber se há mais.
    def page(scope, column, limit:, position:)
      table = scope.klass.arel_table
      rows = CareLines::Cursor.before(scope.reorder(table[column].desc, table[:id].desc), position, column).limit(limit + 1).to_a
      shown = rows.first(limit)
      [ shown, rows.size > limit ? CareLines::Cursor.encode(shown.last.public_send(column), shown.last.id) : nil ]
    end
  end
end
