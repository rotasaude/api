# Superfície de autoria de protocolo (editor do dashboard, F-03.12).
# Sessão municipal (ADR-0022) + tenant-scoped (RLS, ADR-0019) + ProtocolPolicy.author?.
# NÃO é /admin/api (read-only §10): aqui há escrita (draft), sob RLS.
module Authoring
  class ProtocolsController < ApplicationController
    include Authentication
    before_action :require_author!

    def gate
      render_gate(Protocols::Gate.call(definition_param))
    end

    def preview
      result = Protocols::Gate.call(definition_param)
      return render_gate(result) unless result.valid?
      outcome = Protocols::Definitions.build(definition_param).evaluate(answers_param)
      render json: { outcome: outcome.to_h }
    end

    def draft
      result = Protocols::SaveDraft.call(definition: definition_param, by: Current.user)
      case result.reason
      when nil
        pd = result.payload[:protocol_definition]
        render json: { id: pd.id, name: pd.name, version: pd.version, status: pd.status }
      when :forbidden
        head :forbidden
      when :version_not_editable
        render json: { error: "version_not_editable", message: result.message }, status: :unprocessable_entity
      else
        render json: { error: "invalid_definition", message: result.message }, status: :unprocessable_entity
      end
    end

    private

    def definition_param
      params.require(:definition).to_unsafe_h
    end

    def answers_param
      params.fetch(:answers, {}).to_unsafe_h
    end

    def render_gate(result)
      if result.valid?
        render json: { valid: true }
      else
        render json: { valid: false, errors: result.errors }, status: :unprocessable_entity
      end
    end

    def require_author!
      record = ProtocolDefinition.new(municipality_id: Current.municipality_id)
      head :forbidden unless ProtocolPolicy.new(Current.user, record).author?
    end
  end
end
