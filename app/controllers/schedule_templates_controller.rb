# Modelos de agenda (ADR 0029 §3.2; contratos §3, §9, §10). Só municipal_admin;
# sem step-up. Escrita devolve o objeto puro.
class ScheduleTemplatesController < ApplicationController
  include Authentication
  include AttendanceAccess

  wrap_parameters false

  ERROR_STATUS = {
    invalid_name: :unprocessable_entity, invalid_fit_in_limit: :unprocessable_entity,
    invalid_blocks: :unprocessable_entity, invalid: :unprocessable_entity
  }.freeze

  before_action :require_admin

  def index
    render json: { templates: ScheduleTemplate.order(:name, :id).map { |t| template_json(t) } }
  end

  def create
    save(nil, status: :created)
  end

  def update
    template = ScheduleTemplate.find_by(id: params[:id].to_s)
    return render(json: { error: "not_found" }, status: :not_found) unless template

    save(template, status: :ok)
  end

  def preview
    result = Scheduling::TemplatePreview.call(blocks: body["blocks"], fit_in_limit: body["fit_in_limit"], sample: body["sample"])
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: result.payload
  end

  private

  def body = @body ||= request.request_parameters.to_h

  def save(template, status:)
    result = Scheduling::SaveTemplate.call(template: template, attrs: body, by: Current.user)
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: template_json(result.payload[:template]), status: status
  end

  def template_json(t)
    { id: t.id, name: t.name, fit_in_limit: t.fit_in_limit, blocks: t.blocks, active: t.active }
  end
end
