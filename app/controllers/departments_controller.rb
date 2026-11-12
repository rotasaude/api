# GET/POST/PATCH /departments (ADR 0051; contrato §7, Q12): setores da
# secretaria, destino dos encaminhamentos da ouvidoria. Tabela genérica, SEM o
# portão `ombudsman`. Leitura: administrador, técnico e ouvidor; escrita: só o
# municipal_admin. Nunca apaga: desativar é `active = false`.
class DepartmentsController < Ombudsman::BaseController
  skip_before_action :require_ombudsman!

  before_action :require_reader!, only: :index
  before_action :require_admin!, only: %i[create update]

  def index
    scope = Department.order(:name, :id)
    scope = scope.active if params[:active] == "true"
    render json: { items: scope.map { |department| json(department) } }
  end

  def create
    return unless query_only!

    result = Ombudsman::SaveDepartment.call(department: nil, attrs: body, by: Current.user)
    return render_failure(result) if result.failure?

    render json: json(result.payload[:department]), status: :created
  end

  def update
    return unless query_only!

    department = uuid?(params[:id]) ? Department.find_by(id: params[:id]) : nil
    return not_found unless department

    result = Ombudsman::SaveDepartment.call(department: department, attrs: body, by: Current.user)
    return render_failure(result) if result.failure?

    render json: json(result.payload[:department])
  end

  private

  def json(department) = { id: department.id, name: department.name, active: department.active }

  def require_reader! = (forbid unless Ombudsman::Access.config_reader?(Current.user))
  def require_admin! = (forbid unless Ombudsman::Access.admin?(Current.user))
end
