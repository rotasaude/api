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

    private

    def definition_param
      params.require(:definition).to_unsafe_h
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
