# Painel "Produção e-SUS" da cidade (ADR 0028; spec §6.5; contratos §5.3).
# Exige ledi_export LIGADO (não precisa estar utilizável: com a credencial
# recusada a cidade ainda vê o que está parado). Nunca devolve payload.
class ProductionController < ApplicationController
  include Authentication
  include MfaStepUp
  include FeatureGate
  include ScalarParams

  wrap_parameters false

  PER_PAGE = 50
  MAX_PAGE = 10_000

  before_action :require_read, only: :show
  before_action :require_resend, only: :resend
  require_feature :ledi_export

  def show
    competence = optional_scalar_param(:competence) || Ledi::Deadline.current(Time.zone.today)
    return render(json: { error: "invalid_competence" }, status: :unprocessable_entity) unless Ledi::Deadline.valid?(competence)

    summary = Ledi::ProductionSummary.call(competence: competence, today: Time.zone.today,
                                           record_mode: Current.city.record_mode)
    render json: {
      competence: summary[:competence], deadline_on: summary[:deadline_on].iso8601,
      business_days_left: summary[:business_days_left], alert: summary[:alert],
      counts: summary[:counts], rejections: summary[:rejections], fichas: fichas(competence),
      fichas_total: LediOutboxEntry.for_competence(competence).count
    }
  end

  def resend
    return require_step_up! unless reauthenticated_recently?

    entry = LediOutboxEntry.find_by(id: params[:id])
    return render(json: { error: "not_found" }, status: :not_found) unless entry

    render json: ficha_json(Ledi::Resend.call(entry: entry, by: Current.user))
  rescue Ledi::Resend::NotRejected
    render json: { error: "not_rejected" }, status: :conflict
  end

  private

  def policy = ProductionPolicy.new(Current.user, nil)

  def require_read = (forbid unless policy.read?)

  def require_resend = (forbid unless policy.resend?)

  def forbid = render(json: { error: "missing_role" }, status: :forbidden)

  def fichas(competence)
    # Fora de 1..MAX_PAGE (ou não inteira) a página é limitada: um número
    # enorme nunca estoura o offset (R35).
    page = (Integer(optional_scalar_param(:page).to_s, 10, exception: false) || 1).clamp(1, MAX_PAGE)
    LediOutboxEntry.for_competence(competence).order(created_at: :desc, id: :desc)
                   .offset((page - 1) * PER_PAGE).limit(PER_PAGE).map { |entry| ficha_json(entry) }
  end

  def ficha_json(entry)
    { id: entry.id, ficha_type: entry.ficha_type, status: entry.status, attempts: entry.attempts,
      last_error: entry.last_error, created_at: entry.created_at.iso8601, accepted_at: entry.accepted_at&.iso8601 }
  end
end
