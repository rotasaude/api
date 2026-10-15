module Lab
  module Admin
    class ReleasersController < BaseController
      def index
        rows = LabReleaser.active.joins(:exam_provider).merge(Lab::Access.labs).includes(user: :professional).order(:created_at)
        render json: { releasers: rows.map { |r| Lab::AdminJson.releaser(r) } }
      end

      def create
        admin_provider!(params[:provider_id])
        return if performed?

        result = Lab::AssignReleaser.call(user_id: params[:user_id], provider: @provider, technical_lead: params[:technical_lead],
                                          technical_deputy: params[:technical_deputy], by: Current.user)
        return render_failure(result) if result.failure?

        render json: Lab::AdminJson.releaser(result.payload[:releaser]), status: :created
      end

      def destroy
        releaser = uuid?(params[:id]) && LabReleaser.active.find_by(id: params[:id])
        return not_found unless releaser

        Lab::AssignReleaser.end!(releaser: releaser, by: Current.user)
        head :no_content
      end
    end
  end
end
