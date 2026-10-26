# /territory/registrations (contrato §5, §14 L3, L4, L7, L9, L11; F-24.3,
# F-24.5): quem cadastra da equipe (Access.registrar?, ficha individual) lê e
# grava. Leitura nominal com trilha clinical_record.viewed (access
# territory_registry), uma por pessoa mostrada; cadastro que o usuário não
# alcança por id → 404. Escrita só pelo corpo JSON; a query só aceita
# patient_id/household_id (CPF ou nome na URL → 422 invalid_request).
module TerritoryRegistry
  class RegistrationsController < BaseController
    def index
      return unless query_only!(:patient_id, :household_id)

      patient_id = params[:patient_id]
      household_id = params[:household_id]
      return render_error("invalid_request") unless [ patient_id, household_id ].compact.one? && uuid?(patient_id || household_id)

      if household_id
        household = Household.includes(micro_area: :team).find_by(id: household_id)
        return not_found unless household && Access.visible_micro_area_ids(Current.user, household.micro_area.team).include?(household.micro_area_id)

        scope = IndividualRegistration.active_registrations.where(household_id: household.id)
      else
        scope = IndividualRegistration.where(patient_id: patient_id)
      end
      rows = scope.includes(:patient, :team, :micro_area, registered_by_user: :professional).order(registered_at: :desc, id: :desc)
                  .select { |registration| readable?(registration) }
      rows.map(&:patient_id).uniq.each { |id| Trail.person_viewed!(user: Current.user, patient_id: id) }
      render json: { registrations: rendered(rows) }
    end

    def show
      registration = find_registration
      return not_found unless registration

      Trail.person_viewed!(user: Current.user, patient_id: registration.patient_id)
      render json: rendered([ registration ]).first
    end

    def create
      respond(SaveRegistration.call(params: body, by: Current.user), :created)
    end

    def update
      registration = find_registration
      return not_found unless registration

      respond(SaveRegistration.call(params: body, by: Current.user, registration: registration), :ok)
    end

    def exit
      registration = find_registration
      return not_found unless registration

      respond(ExitRegistration.call(registration: registration, params: body, by: Current.user), :ok)
    end

    private

    def find_registration
      registration = uuid?(params[:id]) && IndividualRegistration.includes(:team, :micro_area).find_by(id: params[:id])
      registration if registration && readable?(registration)
    end

    # Lê quem poderia gravar o cadastro onde ele está (equipe e microárea).
    def readable?(registration) = Access.reads_registration?(Current.user, registration)

    # A resposta da escrita mostra o que o autor gravou (sem trilha, como o domicílio).
    def respond(result, status)
      return render_failure(result) if result.failure?

      render json: rendered([ result.payload[:registration].reload ]).first, status: status
    end

    # A última versão de cada cadastro e se o paciente tem par validado.
    def rendered(registrations)
      ids = registrations.map(&:id)
      versions = IndividualRegistrationVersion.joins(:registration).where(registration_id: ids)
                                              .where("individual_registration_versions.version = individual_registrations.version")
                                              .index_by(&:registration_id)
      # A mesma regra que a gravação aplica (identity_locked): Patients::Pairs.of.
      locked = Patients::Pairs.patient_ids_with_pairs(registrations.map(&:patient).uniq)
      registrations.map do |registration|
        Json.registration(registration, versions.fetch(registration.id), identity_locked: locked.include?(registration.patient_id))
      end
    end
  end
end
