module Lab
  module Admin
    class ExamsController < BaseController
      before_action :admin_provider!, only: %i[index create]
      before_action :load_exam, only: %i[show update create_version]

      def index
        exams = LabExam.where(exam_provider_id: @provider.id).includes(current_version: :created_by_user).order(:name)
        render json: { exams: exams.map { |e| Lab::AdminJson.exam(e) } }
      end

      def show = render(json: Lab::AdminJson.exam(@exam, versions: true))

      def create
        result = Lab::AdoptExam.call(provider: @provider, template_id: params[:template_id], sector: params[:sector],
                                     bench: params[:bench], delivery_days: params[:delivery_days], by: Current.user)
        return render_failure(result) if result.failure?

        render json: Lab::AdminJson.exam(result.payload[:exam].reload, versions: true), status: :created
      end

      def update
        sector, bench, days, active = params.values_at(:sector, :bench, :delivery_days, :active)
        return render_failure(Result.fail(:invalid_sector)) unless LabExam::SECTORS.include?(sector)
        return render_failure(Result.fail(:invalid_delivery_days)) unless days.is_a?(Integer) && days.between?(1, 90)
        return render_failure(Result.fail(:invalid_active)) unless [ true, false ].include?(active)
        return render_failure(Result.fail(:invalid_bench)) unless bench.nil? || (bench.is_a?(String) && bench.strip.length <= 60)

        @exam.update!(sector: sector, bench: bench&.strip.presence, delivery_days: days, active: active)
        render json: Lab::AdminJson.exam(@exam, versions: true)
      end

      def create_version
        result = Lab::CreateVersion.call(exam: @exam, params: body_params, by: Current.user)
        return render_failure(result) if result.failure?

        render json: Lab::AdminJson.version(result.payload[:version]), status: :created
      end

      private

      def load_exam
        @exam = uuid?(params[:id]) && LabExam.find_by(id: params[:id])
        not_found unless @exam
      end
    end
  end
end
