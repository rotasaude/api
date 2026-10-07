# Superfície de autoria de protocolo (editor do dashboard, F-03.12).
# Sessão municipal (ADR-0011) + banco da cidade do host (CityResolution) + ProtocolPolicy.author?.
# NÃO é /admin/api (read-only §10): aqui há escrita (draft).
module Authoring
  class ProtocolsController < ApplicationController
    include Authentication
    before_action :require_author!, except: %i[simulate_offer simulate_screening]
    before_action :require_simulator!, only: %i[simulate_offer simulate_screening]

    def gate
      definition = definition_param
      warnings = Protocols::SuggestionTargets.warnings(definition) + Protocols::SchedulingTargets.warnings(definition)
      render_gate(Protocols::Gate.call(definition), warnings: warnings)
    end

    def preview
      # ADR 0030: a escuta não tem passos para simular resposta.
      if Protocols::Validation::Screening.screening?(definition_param)
        return render(json: { valid: false, errors: [ "preview is not available for screening protocols" ] },
                      status: :unprocessable_entity)
      end

      result = Protocols::Gate.call(definition_param)
      return render_gate(result) unless result.valid?
      outcome = Protocols::Definitions.build(definition_param).evaluate(answers_param)
      render json: { outcome: outcome.to_h }
    end

    # ADR 0027 (contratos §4.3): autor e revisor; sempre 200, nunca grava.
    def simulate_offer
      # Definição que não é objeto (ou ausente) vai como nil: o simulador responde
      # 200 com o erro, nunca 422/500 (contratos §4.3).
      render json: Protocols::SimulateOffer.call(definition: hash_param(:definition, nil), profile: hash_param(:profile),
                                                 answers: hash_param(:answers), outcome: hash_param(:outcome))
    end

    # ADR 0030 (contrato §9): simula a cor da definição em edição; sempre 200.
    def simulate_screening
      render json: Protocols::SimulateScreening.call(definition: hash_param(:definition, nil), vitals: hash_param(:vitals),
                                                     ciap2_code: params[:ciap2_code].is_a?(String) ? params[:ciap2_code] : nil,
                                                     profile: hash_param(:profile))
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

    def definition
      record = ProtocolDefinition.find_by(name: params[:name], version: params[:version])
      return head :not_found unless record
      render json: { definition: record.definition }
    end

    private

    def definition_param
      params.require(:definition).to_unsafe_h
    end

    def answers_param
      params.fetch(:answers, {}).to_unsafe_h
    end

    def hash_param(key, fallback = {})
      value = params[key]
      value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : fallback
    end

    def render_gate(result, warnings: [])
      extra = warnings.any? ? { warnings: warnings } : {}
      if result.valid?
        render json: { valid: true }.merge(extra)
      else
        render json: { valid: false, errors: result.errors }.merge(extra), status: :unprocessable_entity
      end
    end

    def require_author!
      head :forbidden unless ProtocolPolicy.new(Current.user, ProtocolDefinition.new).author?
    end

    def require_simulator!
      return if ProtocolPolicy.new(Current.user, ProtocolDefinition.new).simulate?

      render json: { error: "missing_role" }, status: :forbidden
    end
  end
end
