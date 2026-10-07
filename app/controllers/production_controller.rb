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
  FAILURES_LIMIT = 200

  before_action :require_read, only: %i[show generation_failures]
  before_action :require_resend, only: %i[resend retry_generation]
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
  rescue Ledi::Resend::ExportUnusable
    render json: { error: "export_unusable" }, status: :conflict
  rescue Ledi::Resend::NotRegenerated
    render json: { error: "generation_failed" }, status: :conflict
  end

  # Fichas que não puderam ser geradas (ADR 0030; contratos §6). Sem o
  # parâmetro: as não resolvidas; até FAILURES_LIMIT, mais novas primeiro.
  def generation_failures
    resolved = optional_scalar_param(:resolved).to_s
    scope = resolved == "true" ? LediGenerationFailure.where.not(resolved_at: nil) : LediGenerationFailure.unresolved
    failures = scope.order(created_at: :desc, id: :desc).limit(FAILURES_LIMIT).to_a
    attendances = Screening.where(id: failures.select { |f| f.source_type == "Screening" }.map(&:source_id))
                           .pluck(:id, :attendance_id).to_h
    render json: { items: failures.map { |f| failure_json(f, attendances[f.source_id]) } }
  end

  def retry_generation
    return require_step_up! unless reauthenticated_recently?

    failure = LediGenerationFailure.find_by(id: params[:id])
    return render(json: { error: "not_found" }, status: :not_found) unless failure

    failure = Ledi::ScreeningFicha.retry!(failure, by: Current.user)
    render json: failure_json(failure, Screening.where(id: failure.source_id).pick(:attendance_id))
  rescue Ledi::ScreeningFicha::AlreadyResolved
    render json: { error: "already_resolved" }, status: :conflict
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

  def failure_json(failure, attendance_id)
    { id: failure.id, source_type: failure.source_type, source_id: failure.source_id, attendance_id: attendance_id,
      reason_codes: failure.reason_codes, created_at: failure.created_at.iso8601,
      resolved_at: failure.resolved_at&.iso8601 }
  end

  def ficha_json(entry)
    { id: entry.id, ficha_type: entry.ficha_type, status: entry.status, attempts: entry.attempts,
      last_error_codes: entry.last_error_codes, replaces_outbox_id: entry.replaces_outbox_id,
      created_at: entry.created_at.iso8601, accepted_at: entry.accepted_at&.iso8601 }
  end
end
