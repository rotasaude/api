#   GET  /citizen/triages?citizen_id=
#   GET  /citizen/triages/:id
#   POST /citizen/triages/:id/revoke_consent
# O nível declarado vê só as triagens do próprio par CPF + telefone (spec §2.3).
module CitizenApi
  class TriagesController < BaseController
    def index
      citizen = current_citizen_session.citizens.find_by(id: params[:citizen_id])
      return render_error("not_found", :not_found) unless citizen

      triages = history_scope(citizen).order(created_at: :desc)
      render json: {
        citizen: {
          id: citizen.id, cpf_masked: citizen.cpf_masked, verification_level: citizen.verification_level,
          verified_at: citizen.active_verification&.verified_at&.iso8601
        },
        triages: triages.map { |t| summary(t, viewer: citizen) }
      }
    end

    def show
      triage = visible_triages.find_by(id: params[:id])
      return render_error("not_found", :not_found) unless triage

      render json: summary(triage)
    end

    def revoke_consent
      triage = visible_triages.find_by(id: params[:id])
      return render_error("not_found", :not_found) unless triage
      return render_error("not_own_triage", :forbidden) unless own_triage?(triage)

      result = RevokeConsent.call(conversation: triage.conversation, reason: "citizen_web")
      return render_error(result.reason, :conflict) if result.failure?

      render json: summary(triage.reload)
    end

    private

    # Par verificado: histórico completo do CPF (spec 2026-09-24 §2.3, §4).
    # Par declarado: só o próprio par (spec 2026-09-22 §2.3).
    def history_scope(citizen)
      ids = citizen.verification_level_verified? ? Citizen.where(cpf: citizen.cpf).select(:id) : [citizen.id]
      Triage.joins(:conversation).where(conversations: { channel: "web", citizen_id: ids })
            .includes(attendance: %i[health_unit referral_unit])
    end

    # Triagens que a sessão pode ver: as dos pares do celular, mais as dos
    # outros pares do CPF de cada par verificado do celular.
    def visible_triages
      own = current_citizen_session.citizens
      verified_cpfs = own.select(&:verification_level_verified?).map(&:cpf)
      ids = Citizen.where(id: own.select(:id)).or(Citizen.where(cpf: verified_cpfs)).select(:id)
      Triage.joins(:conversation).where(conversations: { channel: "web", citizen_id: ids })
            .includes(attendance: %i[health_unit referral_unit])
    end

    def own_triage?(triage)
      current_citizen_session.citizens.exists?(id: triage.conversation.citizen_id)
    end

    def summary(triage, viewer: nil)
      own = viewer ? triage.conversation.citizen_id == viewer.id : own_triage?(triage)
      {
        id: triage.id,
        status: triage.status,
        tier: triage.tier,
        priority: triage.priority,
        created_at: triage.created_at.iso8601,
        completed_at: triage.completed_at&.iso8601,
        report_url: triage.report_snapshot&.url,
        consent_active: own && triage.conversation.active_consent.present?,
        origin_phone_masked: own ? nil : CitizenIdentity::Phone.mask(triage.conversation.citizen.phone),
        attendance: attendance_json(triage.attendance),
        check_in_available: own && Attendances::CheckInEligibility.check(triage) == :ok
      }
    end

    def attendance_json(attendance)
      return nil unless attendance

      {
        status: attendance.status, unit_name: attendance.health_unit.name,
        checked_in_at: attendance.checked_in_at.iso8601, outcome: attendance.outcome,
        referral_unit_name: attendance.referral_unit&.name, referral_note: attendance.referral_note,
        closed_at: attendance.closed_at&.iso8601
      }
    end
  end
end
