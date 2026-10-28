# GET /attendance/consultations/:id/notification_suggestions (contrato §4, K4):
# as doenças da lista que os itens `add` da consulta sugerem e que ainda não
# têm notificação aberta ou recente. Só a autora (rascunho ou finalizada),
# profissional de saúde; leitura de catálogo e de itens da própria consulta,
# sem trilha e sem escrita.
module Surveillance
  class ConsultationSuggestionsController < BaseController
    before_action :require_surveillance_consultation!
    before_action { forbid unless Current.user.has_role?("health_professional") }

    def index
      consultation = uuid?(params[:id]) && Consultation.where.not(status: "discarded").find_by(id: params[:id])
      return not_found unless consultation
      return forbid("not_author") unless consultation.author_user_id == Current.user.id

      suggestions = ConsultationSuggestions.for(consultation).map do |s|
        { disease: s[:disease].to_json_hash, matched_code: s[:matched_code] }
      end
      render json: { suggestions: suggestions }
    end
  end
end
