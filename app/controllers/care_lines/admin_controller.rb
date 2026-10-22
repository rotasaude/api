# /care_lines/admin (contrato §3): municipal_admin; escrita com step-up.
module CareLines
  class AdminController < BaseController
    before_action { forbid unless Access.admin?(Current.user) }
    before_action :require_step_up!, only: %i[create update]

    def templates = render(json: { templates: CareLineTemplate.latest.map { |t| Json.template(t) } })

    def index
      latest = latest_versions
      render json: { lines: CareLine.order(:name, :id).map { |l| Json.line(l, latest: latest) } }
    end

    def create
      result = SaveLine.call(params: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.line(result.payload[:line], latest: latest_versions), status: :created
    end

    def update
      line = uuid?(params[:id]) && CareLine.find_by(id: params[:id])
      return not_found unless line

      result = SaveLine.call(params: body, by: Current.user, line: line)
      return render_failure(result) if result.failure?

      render json: Json.line(result.payload[:line], latest: latest_versions)
    end

    private

    # Maior versão por chave no catálogo-base (uma consulta; §11 T5).
    def latest_versions = CareLineTemplate.group(:key).maximum(:version)
  end
end
