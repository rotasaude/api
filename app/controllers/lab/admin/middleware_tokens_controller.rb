module Lab
  module Admin
    class MiddlewareTokensController < BaseController
      before_action { admin_provider!(params[:id]) }

      def create
        render json: { token: Lab::RotateMiddlewareToken.call(provider: @provider, by: Current.user).payload[:token] }, status: :created
      end

      def destroy
        Lab::RotateMiddlewareToken.revoke(provider: @provider)
        head :no_content
      end
    end
  end
end
