# /territory/registry_status (contrato §6; §14 L10, L12, L19; F-24.6):
# validade de 24 meses e quem falta cadastrar. Lista nominal só para membro
# da equipe com papel de cadastro (enfermeiro/médico em qualquer microárea, o
# ACS só na sua: micro_area_id obrigatório para ele), com trilha
# clinical_record.viewed uma por pessoa mostrada (person_ref). Contagem sem
# trilha, também para municipal_admin e analyst. Equipe alheia, microárea de
# outra equipe ou do ACS alheio → 403 out_of_scope. Só ids e filtros na URL.
module TerritoryRegistry
  class RegistryStatusController < BaseController
    def index
      scope = read_scope(nominal: true)
      return render_error(*scope) if scope.is_a?(Array)

      limit = page_limit
      return unless limit

      status = params[:status].presence
      return render_error("invalid_request") if status && !RegistryStatus::LISTED.include?(status)

      before = params[:before].presence
      return render_error("invalid_cursor") if before && !(before.is_a?(String) && before.match?(RegistryStatus::PERSON_REF))

      result = RegistryStatus.page(team: scope[:team], micro_area: scope[:micro_area], status: status, before: before&.downcase,
                                   limit: limit, today: Time.zone.today)
      result[:people].each { |row| Trail.person_viewed!(user: Current.user, patient_id: row[:patient_id], citizen_id: row[:citizen_id]) }
      render json: result
    end

    def count
      scope = read_scope(nominal: false)
      return render_error(*scope) if scope.is_a?(Array)

      render json: RegistryStatus.count(team: scope[:team], micro_area: scope[:micro_area], today: Time.zone.today)
    end

    private

    # { team:, micro_area: } ou [motivo, status HTTP] da recusa.
    def read_scope(nominal:)
      return [ "invalid_request" ] unless uuid?(params[:team_id])

      team = HealthTeam.find_by(id: params[:team_id])
      return [ "not_found", :not_found ] unless team

      area = nil
      if params[:micro_area_id].present?
        return [ "invalid_request" ] unless uuid?(params[:micro_area_id])

        area = MicroArea.find_by(id: params[:micro_area_id])
        return [ "not_found", :not_found ] unless area
        return [ "out_of_scope", :forbidden ] unless area.team_id == team.id
      end
      return [ "out_of_scope", :forbidden ] unless allowed?(team, area, nominal: nominal)

      { team: team, micro_area: area }
    end

    # A gestão só conta; o membro lê pela regra do Access.status_reader.
    def allowed?(team, area, nominal:)
      return true if !nominal && Access.manager?(Current.user)

      case Access.status_reader(Current.user, team)
      when :team then true
      when :acs then area.present? && area.acs_professional_id == Current.user.professional.id
      else false
      end
    end
  end
end
