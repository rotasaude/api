# Perfil do profissional (ADR 0021; spec 2026-09-27 §4.1). Admin cadastra e
# edita; o próprio profissional lê e edita nome e contato.
class ProfessionalsController < ApplicationController
  include Authentication
  include AttendanceAccess
  include ProfessionalRendering

  wrap_parameters false

  ERROR_STATUS = {
    not_found: :not_found, missing_role: :unprocessable_entity, already_exists: :conflict,
    invalid: :unprocessable_entity, cns_taken: :conflict, registration_taken: :conflict,
    field_not_editable: :unprocessable_entity
  }.freeze
  UPCOMING_DAYS = 14

  before_action :require_admin, except: %i[me update_me]
  before_action :set_professional, only: %i[show update]

  def index
    professionals = Professional.includes(:user, links: %i[health_unit started_by_user ended_by_user])
                                .order(:professional_name)
    render json: { professionals: professionals.map { |p| profile_json(p, full: false).merge(links: p.links.sort_by(&:started_at).map { |l| link_json(l) }) } }
  end

  def pending
    users = User.joins(:memberships).merge(Membership.active.where(role: "health_professional"))
                .where(deactivated_at: nil).distinct.order(:email_address).to_a
    status = Professionals::Status.for_users(users.map(&:id))
    rows = users.reject { |u| status[u.id] == "ok" }
                .map { |u| { user_id: u.id, email_address: u.email_address, status: status[u.id] } }
    render json: { users: rows }
  end

  def show
    render json: { professional: profile_json(@professional, full: true),
                   links: @professional.links.includes(:health_unit, :started_by_user, :ended_by_user)
                                       .order(:started_at).map { |l| link_json(l) } }
  end

  def create
    body = scalar_body([ "user_id", *Professional::FIELDS ])
    return render(json: { error: "invalid" }, status: :unprocessable_entity) if body.value?(:non_scalar)

    result = Professionals::Create.call(user_id: body["user_id"], attrs: body.except("user_id"), by: Current.user)
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: { professional: profile_json(result.payload[:professional], full: true) }, status: :created
  end

  def update
    update_with(@professional, allowed: Professional::FIELDS)
  end

  def me
    professional = Current.user.professional
    return render(json: { error: "no_profile" }, status: :not_found) unless professional

    window = Time.current..UPCOMING_DAYS.days.from_now
    shifts = ProfessionalShift.valid_shifts.where(professional: professional, starts_at: window)
                              .includes(professional_link: :health_unit).order(:starts_at)
    render json: {
      professional: profile_json(professional, full: true),
      links: professional.links.active.includes(:health_unit, :started_by_user, :ended_by_user)
                         .order(:started_at).map { |l| link_json(l) },
      shifts: shifts.map { |s| shift_json(s) }
    }
  end

  def update_me
    professional = Current.user.professional
    return render(json: { error: "no_profile" }, status: :not_found) unless professional

    update_with(professional, allowed: Professional::SELF_EDITABLE)
  end

  private

  def set_professional
    @professional = Professional.find_by(id: params[:id])
    render json: { error: "not_found" }, status: :not_found unless @professional
  end

  def update_with(professional, allowed:)
    body = scalar_body
    return render(json: { error: "invalid" }, status: :unprocessable_entity) if body.value?(:non_scalar)

    result = Professionals::UpdateProfile.call(professional: professional, attrs: body, by: Current.user, allowed: allowed)
    return render_failure(result, ERROR_STATUS) if result.failure?

    render json: { professional: profile_json(result.payload[:professional], full: true) }
  end
end
