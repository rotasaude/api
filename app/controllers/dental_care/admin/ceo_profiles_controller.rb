# /dental/admin/ceo_profiles (contrato §16 O14): a lista (admin e analista) e o
# perfil de uma unidade `ceo` (admin; escrita com step-up).
module DentalCare
  module Admin
    class CeoProfilesController < BaseController
      before_action(only: :index) { forbid unless panel_reader? }
      before_action(only: %i[show update]) { forbid unless admin? }
      before_action :require_step_up!, only: :update
      before_action :load_unit, only: %i[show update]

      def index
        limit = page_limit or return
        units = HealthUnit.where(kind: "ceo").includes(:ceo_profile).order(:name, :id).limit(limit)
        render json: { profiles: units.map { |unit| profile_json(unit, unit.ceo_profile) } }
      end

      def show = render(json: profile_json(@unit, @unit.ceo_profile))

      def update
        result = SaveCeoProfile.call(unit: @unit, params: body, by: Current.user)
        return render_failure(result) if result.failure?

        render json: profile_json(@unit, result.payload.fetch(:profile))
      end

      private

      def load_unit
        @unit = uuid?(params[:health_unit_id]) ? HealthUnit.find_by(id: params[:health_unit_id]) : nil
        not_found unless @unit
      end

      def profile_json(unit, profile)
        { health_unit: { id: unit.id, name: unit.name, kind: unit.kind },
          ceo_type: profile&.ceo_type, specialties: profile ? profile.specialties : [] }
      end
    end
  end
end
