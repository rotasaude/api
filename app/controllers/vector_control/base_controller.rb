# Base das rotas /vector_control/* (módulo 35a, ADR 0054; contrato §12; plano,
# Valor fixado 4): sessão do dashboard e `vector_control` utilizável (403
# feature_disabled; o interruptor é lido aqui, fora da transação da cidade).
# Escrita só pelo corpo JSON: a query de uma rota que grava (ou com texto) é
# recusada com 422 invalid_request. Recusas `{ error, path? }` e nada mais:
# nunca nome, CPF, CNS, telefone ou endereço de pessoa.
module VectorControl
  class BaseController < ApplicationController
    include Authentication
    include MfaStepUp
    include ::VectorControlGate
    include ::FieldListQuery

    wrap_parameters false

    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    # O resto das recusas é 422 (inclusive sample_label_taken, Q7(1)).
    # client_uuid_conflict só na instalação de ovitrampa com o client_uuid de
    # outro usuário. invalid_transition sempre com path status (Q9).
    FAILURE_STATUS = {
      mfa_required: :unauthorized,
      feature_disabled: :forbidden, cbo_not_allowed: :forbidden, out_of_scope: :forbidden, missing_role: :forbidden,
      not_found: :not_found,
      block_in_use: :conflict, product_in_use: :conflict, already_reconciled: :conflict, survey_not_draft: :conflict,
      invalid_transition: :conflict, unit_has_vector_control_location: :conflict, visit_changed: :conflict,
      client_uuid_conflict: :conflict
    }.freeze

    before_action :require_vector_control!

    private

    def render_failure(result)
      render_refusal(result.reason, path: result.details[:path])
    end

    def render_refusal(error, path: nil)
      payload = { error: error.to_s }
      payload[:path] = path if path
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

    # Cursor opaco `before` (CareLines::Cursor): ausente → nil; inválido → 422
    # invalid_cursor (performed?).
    def cursor
      CareLines::Cursor.decode(request.query_parameters["before"])
    rescue CareLines::Cursor::Invalid
      render_refusal("invalid_cursor")
      nil
    end

    # Página `{ items, next_before }` de `scope` (mais recente primeiro por
    # `column`, id): `limit + 1` linhas para saber se há mais.
    def page(scope, column, limit:, position:)
      table = scope.klass.arel_table
      rows = CareLines::Cursor.before(scope.reorder(table[column].desc, table[:id].desc), position, column).limit(limit + 1).to_a
      shown = rows.first(limit)
      [ shown, rows.size > limit ? CareLines::Cursor.encode(shown.last.public_send(column), shown.last.id) : nil ]
    end

    # Só a endemic_coordinator; senão 403 missing_role (false).
    def coordinator!
      return true if Access.coordinator?(Current.user)

      forbid
      false
    end
  end
end
