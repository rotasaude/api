# Ações da equipe sobre a manifestação (ADR 0051; contrato §2, §5; §16 Q32;
# preflight F-11): uma rota explícita por ação
# (`POST /ombudsman/manifestations/:id/<ação>` → `actions#<ação>`), um método
# por ação, cada um chamando o seu comando — que trava a manifestação
# (Ombudsman::Lock) e confere `expected_state` (409 manifestation_changed).
# Técnico ou ouvidor (o respondente sem ombudsman_staff → 403); `extend` e
# `change_resolution` só o ouvidor. Sucesso → 200 com o detalhe atualizado
# (Ombudsman::Json.detail, relido depois do commit, para o usuário da sessão;
# Q32). Corpo só com as chaves da ação e nada na query (422 com o nome da
# chave); id malformado ou inexistente → 404.
#   classify           { expected_state, subject_id, kind?, health_unit_id?, professional_id?, urgent? }
#   forward            { expected_state, department_id | health_unit_id, extract }
#   request_complement { expected_state, text }
#   complement         { expected_state, text, attachment_ids? } (o recebido por outro canal)
#   extend             { expected_state, text }                  (ouvidor; método extend_deadline)
#   interim_response   { expected_state, text }
#   final_response     { expected_state, text, resolution? }
#   change_resolution  { expected_state, resolution, text }      (ouvidor)
#   archive            { expected_state, reason, duplicate_of_protocol? | duplicate_of_id?, external_body_name? } (ouvidor)
#   reopen             { expected_state, text? }                 (ouvidor)
# `archive` com `no_complement` → 422 path reason (Q36: só o job diário o usa,
# chamando o comando direto). Na duplicidade a tela pode mandar o protocolo da
# original (Q26, A28): aqui vira o id (protocolo desconhecido → 422 path
# duplicate_of_protocol); os dois juntos → 422 path duplicate_of_id.
# O método da rota `…/extend` é `extend_deadline`: uma ação `extend`
# sobrescreveria Object#extend no controlador.
module Ombudsman
  class ActionsController < BaseController
    KEYS = {
      "classify" => %w[expected_state subject_id kind health_unit_id professional_id urgent],
      "forward" => %w[expected_state department_id health_unit_id extract],
      "request_complement" => %w[expected_state text],
      "complement" => %w[expected_state text attachment_ids],
      "extend_deadline" => %w[expected_state text],
      "interim_response" => %w[expected_state text],
      "final_response" => %w[expected_state text resolution],
      "change_resolution" => %w[expected_state resolution text],
      "archive" => %w[expected_state reason duplicate_of_protocol duplicate_of_id external_body_name],
      "reopen" => %w[expected_state text]
    }.freeze
    OMBUDSMAN_ONLY = %w[extend_deadline change_resolution archive reopen].freeze
    PROTOCOL = /\A\d{4}-\d{6,}\z/

    before_action :require_staff!
    before_action :require_ombudsman_role!, if: -> { OMBUDSMAN_ONLY.include?(action_name) }
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

    def request_complement
      respond RequestComplement.call(manifestation_id: params[:id], expected_state: body_param("expected_state"),
                                     text: body_param("text"), by: Current.user)
    end

    def complement
      manifestation = OmbudsmanManifestation.find_by(id: params[:id])
      return not_found unless manifestation

      respond RecordComplement.call(manifestation: manifestation, expected_state: body_param("expected_state"),
                                    text: body_param("text"), attachment_ids: body_param("attachment_ids"),
                                    actor: "staff", by: Current.user, owner: Current.user)
    end

    def extend_deadline
      respond Extend.call(manifestation_id: params[:id], expected_state: body_param("expected_state"), text: body_param("text"),
                          by: Current.user)
    end

    def interim_response
      respond InterimResponse.call(manifestation_id: params[:id], expected_state: body_param("expected_state"),
                                   text: body_param("text"), by: Current.user)
    end

    def final_response
      respond FinalResponse.call(manifestation_id: params[:id], expected_state: body_param("expected_state"),
                                 text: body_param("text"), resolution: body_param("resolution"), by: Current.user)
    end

    def change_resolution
      respond ChangeResolution.call(manifestation_id: params[:id], expected_state: body_param("expected_state"),
                                    resolution: body_param("resolution"), text: body_param("text"), by: Current.user)
    end

    def archive
      reason = body_param("reason")
      return render_refusal("reason") if reason == "no_complement"

      duplicate_of_id = body_param("duplicate_of_id")
      if body.key?("duplicate_of_protocol")
        protocol = body_param("duplicate_of_protocol")
        return render_refusal("duplicate_of_id") unless duplicate_of_id.nil?
        return render_refusal("duplicate_of_protocol") unless reason == "duplicate" && protocol.is_a?(String) && protocol.match?(PROTOCOL)

        duplicate_of_id = OmbudsmanManifestation.where(protocol: protocol).pick(:id)
        return render_refusal("duplicate_of_protocol") unless duplicate_of_id
      end
      respond Archive.call(manifestation_id: params[:id], expected_state: body_param("expected_state"), reason: reason,
                           duplicate_of_id: duplicate_of_id, external_body_name: body_param("external_body_name"), by: Current.user)
    end

    def reopen
      respond Reopen.call(manifestation_id: params[:id], expected_state: body_param("expected_state"), text: body_param("text"),
                          by: Current.user)
    end

    private

    def respond(result) = result.failure? ? render_failure(result) : render_detail(params[:id])
  end
end
