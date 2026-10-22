# Painel nominal e busca ativa (contrato §5; §11 L6, L7, L12). health_professional
# com vínculo na unidade da equipe; lista ou criação com equipe alheia → 403
# out_of_scope; registro de outra equipe por id → 404. Os comandos não conferem
# o painel: quem confere é este controller. Leitura nominal com trilha (uma
# por pessoa mostrada); o contador não grava trilha. O Enroll nunca roda numa
# transação externa (o Resolve fecha a sua antes; ordem de travas do Desvio 8).
module CareLines
  class EnrollmentsController < BaseController
    before_action :load_enrollment, only: %i[show end_enrollment contacts]

    def index
      team = scoped_team or return
      status = params[:status].presence || "all"
      return render_error(:invalid_filter) unless Board::FILTERS.include?(status)
      return render_error(:invalid_filter) if params[:care_line_id].present? && !uuid?(params[:care_line_id])

      page = Board.page(team: team, line_id: params[:care_line_id].presence, status: status, before: Cursor.decode(params[:before]),
                        limit: Timeline::Query.limit(params[:limit]), today: Time.zone.today)
      contacts = last_contacts(page[:rows].map { |enrollment, _| enrollment.id })
      payload = page[:rows].map do |enrollment, row|
        Trail.viewed!(user: Current.user, patient_id: enrollment.patient_id, citizen_id: nil, enrollment_id: enrollment.id)
        Json.enrollment(enrollment, row: row, last_contact: contacts[enrollment.id])
      end
      render json: { enrollments: payload, next_before: page[:next_before] }
    rescue Cursor::Invalid
      render_error(:invalid_cursor)
    end

    def overdue_count
      team = scoped_team or return
      render json: { count: Board.overdue_count(team, today: Time.zone.today) }
    end

    def show
      render json: detail(@enrollment)
    end

    def create
      team = scoped_team or return
      # Errata C-api-08: antes de resolver a pessoa, para quem não confirma não criar paciente.
      return forbid("cbo_not_allowed") unless Access.confirmer?(Current.user, team)

      line = uuid?(params[:care_line_id]) && CareLine.find_by(id: params[:care_line_id])
      return render_error(:invalid_care_line) unless line
      # Recusas puras do Enroll ANTES do Patients::Resolve (como o AcceptSuggestion):
      # um 4xx não cria paciente, não liga o par nem publica evento.
      return render_failure(Result.fail(:line_inactive)) unless line.active

      anchor = Enroll.validate_anchor(line, params[:anchor_date], Time.zone.today)
      return render_failure(anchor) if anchor.is_a?(Result)

      patient = person_patient or return
      result = Enroll.call(patient: patient, line: line, team: team, by: Current.user, anchor_date: params[:anchor_date])
      return render_failure(result) if result.failure?

      render json: detail(result.payload[:enrollment]), status: :created
    end

    def end_enrollment
      result = EndEnrollment.call(enrollment: @enrollment, reason: params[:reason], note: params[:note], by: Current.user)
      return render_failure(result) if result.failure?

      render json: detail(@enrollment.reload)
    end

    def contacts
      result = RecordContact.call(enrollment: @enrollment, channel: params[:channel], outcome: params[:outcome], note: params[:note],
                                  by: Current.user)
      return render_failure(result) if result.failure?

      render json: { contact: Json.contact(result.payload[:contact]) }, status: :created
    end

    private

    def load_enrollment
      @enrollment = uuid?(params[:id]) && CareLineEnrollment.includes(:team, :care_line, :patient).find_by(id: params[:id])
      not_found unless @enrollment && Access.panel?(Current.user, @enrollment.team)
    end

    # patient_id XOR citizen_id; o par precisa ser validado (o paciente
    # nasce por Patients::Resolve, como no aceite da sugestão).
    def person_patient
      patient_id, citizen_id = params.values_at(:patient_id, :citizen_id)
      unless patient_id.present? ^ citizen_id.present?
        render_error(:invalid_person)
        return nil
      end
      record = if patient_id.present?
                 uuid?(patient_id) && Patient.find_by(id: patient_id)
               else
                 uuid?(citizen_id) && Citizen.not_erased.find_by(id: citizen_id)
               end
      unless record
        not_found
        return nil
      end
      return record if record.is_a?(Patient)

      resolved = Patients::Resolve.call(record)
      return resolved.payload[:patient] if resolved.ok?

      render_error(:citizen_not_verified, :conflict)
      nil
    end

    def detail(enrollment)
      row = Evaluation.enrollments([ enrollment ], today: Time.zone.today).fetch(enrollment.id)
      Trail.viewed!(user: Current.user, patient_id: enrollment.patient_id, citizen_id: nil, enrollment_id: enrollment.id)
      Json.enrollment(enrollment, row: row, last_contact: enrollment.contacts.first)
          .merge(contacts: enrollment.contacts.includes(recorded_by_user: :professional).map { |c| Json.contact(c) })
    end

    def last_contacts(ids)
      return {} if ids.empty?

      CareOutreachContact.where(enrollment_id: ids).select("DISTINCT ON (enrollment_id) care_outreach_contacts.*")
                         .order(:enrollment_id, recorded_at: :desc, id: :desc).index_by(&:enrollment_id)
    end
  end
end
