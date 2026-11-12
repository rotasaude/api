# Ações da equipe sobre a manifestação (ADR 0051; contrato §2, §5; §16 Q32;
# preflight F-11): uma rota explícita por ação
# (`POST /ombudsman/manifestations/:id/<ação>` → `actions#<ação>`), um método
# por ação, cada um chamando o seu comando — que trava a manifestação
# (Ombudsman::Lock) e confere `expected_state` (409 manifestation_changed).
# Técnico ou ouvidor (o respondente sem ombudsman_staff → 403). Sucesso → 200
# com o detalhe atualizado (Ombudsman::Json.detail, relido depois do commit,
# para o usuário da sessão; Q32). Corpo só com as chaves da ação e nada na
# query (422 com o nome da chave); id malformado → 404.
#   classify { expected_state, subject_id, kind?, health_unit_id?, professional_id?, urgent? }
#   forward  { expected_state, department_id | health_unit_id, extract }
module Ombudsman
  class ActionsController < BaseController
    KEYS = {
      "classify" => %w[expected_state subject_id kind health_unit_id professional_id urgent],
      "forward" => %w[expected_state department_id health_unit_id extract]
    }.freeze

    before_action :require_staff!
    before_action -> { body_keys!(KEYS.fetch(action_name)) }
    before_action :uuid_id!

    def classify
      respond Classify.call(manifestation_id: params[:id], expected_state: body_param("expected_state"),
                            attrs: body.except("expected_state"), by: Current.user)
    end

    def forward
      respond Forward.call(manifestation_id: params[:id], expected_state: body_param("expected_state"),
                           department_id: body_param("department_id"), health_unit_id: body_param("health_unit_id"),
                           extract: body_param("extract"), by: Current.user)
    end

    private

    def respond(result) = result.failure? ? render_failure(result) : render_detail(params[:id])
  end
end
