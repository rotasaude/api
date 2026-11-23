# /zoonoses/campaigns (módulo 35b, ADR 0054; contrato §3, §10): a campanha
# antirrábica. Leitura reader? (team? ou municipal_admin); escrita só a
# coordenação (403 missing_role).
#   - GET /campaigns → `{ items }`, mais recente primeiro (início, criação);
#   - POST /campaigns (Zoonoses::SaveCampaign) → 201 com a campanha;
#   - PATCH /campaigns/:id com expected_version, só em planned → a campanha;
#   - POST /campaigns/:id/open e /close, sem corpo → a campanha (409
#     campaign_already_open; fora da etapa, 409 invalid_transition path status).
# O semanal não tem rota aqui: sai pelo relatório rabies_weekly (Task 15).
# Toda rota recusa query (422 invalid_request, nada lido da URL).
module Zoonoses
  class CampaignsController < BaseController
    before_action :reader!, only: :index
    before_action :coordinator!, except: :index
    before_action { query_only! }
    before_action :load_campaign, only: %i[update open_campaign close_campaign]

    def index
      campaigns = RabiesCampaign.order(starts_on: :desc, created_at: :desc, id: :desc).to_a
      render json: { items: campaigns.map { Json.campaign(_1) } }
    end

    def create
      result = SaveCampaign.call(params: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.campaign(result.payload.fetch(:campaign)), status: :created
    end

    def update
      respond(SaveCampaign.call(params: body, by: Current.user, campaign: @campaign))
    end

    def open_campaign
      return render_refusal("invalid_request", path: body.keys.first.to_s[0, 64]) if body.any?

      respond(SaveCampaign.open(campaign: @campaign, by: Current.user))
    end

    def close_campaign
      return render_refusal("invalid_request", path: body.keys.first.to_s[0, 64]) if body.any?

      respond(SaveCampaign.close(campaign: @campaign, by: Current.user))
    end

    private

    def load_campaign
      @campaign = uuid?(params[:id]) ? RabiesCampaign.find_by(id: params[:id]) : nil
      not_found unless @campaign
    end

    def respond(result)
      return render_failure(result) if result.failure?

      render json: Json.campaign(result.payload.fetch(:campaign))
    end
  end
end
