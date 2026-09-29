# app/controllers/campaigns_controller.rb
# Campanhas da cidade (ADR 0024; spec 2026-09-29 §6.1): só campaign_manager.
# Prefixo único /campaigns (uma entrada só no proxy de dev do dashboard); a
# escrita fica fora de /admin/api, que segue só leitura. Nenhuma resposta traz
# a lista de destinatários.
class CampaignsController < ApplicationController
  include Authentication
  include MfaStepUp

  wrap_parameters false

  ERROR_STATUS = {
    invalid_campaign: :unprocessable_entity, invalid_audience: :unprocessable_entity,
    below_minimum: :unprocessable_entity, not_editable: :unprocessable_entity,
    invalid_transition: :unprocessable_entity, invalid_send_at: :unprocessable_entity
  }.freeze

  before_action :require_campaign_manager
  before_action :set_campaign, only: %i[show update]

  def index
    campaigns = Campaign.order(created_at: :desc, id: :desc)
    render json: { campaigns: campaigns.map { |c| Campaigns::Presenter.summary(c) } }
  end

  def options
    completed = Triage.where(status: "completed")
    render json: {
      protocols: completed.distinct.order(:protocol_name).pluck(:protocol_name),
      tiers: completed.where.not(tier: nil).distinct.order(:tier).pluck(:tier),
      outcomes: Attendance::OUTCOMES,
      neighborhoods: Neighborhood.active_neighborhoods.order(:name).map { |n| { id: n.id, name: n.name } },
      units: HealthUnit.where(active: true).order(:name).map { |u| { id: u.id, name: u.name } }
    }
  end

  def preview
    audience = body_params["audience"]
    errors = Campaigns::AudienceValidation.errors(audience)
    return render(json: { error: "invalid_audience", details: errors }, status: :unprocessable_entity) if errors.any?

    render json: Campaigns::Audience.new(audience).preview
  end

  def create
    respond(Campaigns::Create.call(attrs: body_params, by: Current.user), status: :created)
  end

  def show
    render json: { campaign: Campaigns::Presenter.full(@campaign) }
  end

  def update
    respond(Campaigns::Update.call(campaign: @campaign, attrs: body_params))
  end

  private

  # Corpo JSON como Hash de chaves de texto (Authentication já exige
  # application/json em toda escrita).
  def body_params
    request.request_parameters
  end

  def require_campaign_manager
    render json: { error: "missing_role" }, status: :forbidden unless CampaignPolicy.new(Current.user, nil).manage?
  end

  def set_campaign
    @campaign = Campaign.find_by(id: params[:id])
    render json: { error: "not_found" }, status: :not_found unless @campaign
  end

  def respond(result, status: :ok)
    if result.failure?
      return render json: { error: result.reason.to_s }.merge(result.details),
                    status: ERROR_STATUS.fetch(result.reason, :unprocessable_entity)
    end

    render json: { campaign: Campaigns::Presenter.full(result.payload[:campaign].reload) }, status: status
  end
end
