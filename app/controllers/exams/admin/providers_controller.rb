module Exams
  module Admin
    class ProvidersController < BaseController
      before_action :load_provider, except: %i[index create]

      def index
        render json: { providers: ExamProvider.order(:name).map { |p| Exams::AdminJson.provider(p) } }
      end

      def create = save(nil, :created)
      def update = save(@provider, :ok)

      def rotate_token
        render json: { token: Exams::RotateFhirToken.call(provider: @provider).payload[:token] }, status: :created
      end

      def revoke_token
        Exams::RotateFhirToken.revoke(provider: @provider)
        head :no_content
      end

      def invite_user
        result = Exams::InviteProviderUser.call(provider: @provider, email: params[:email], invited_by: Current.user)
        return render(json: { error: result.reason.to_s }, status: :unprocessable_entity) if result.failure?

        invitation = result.payload[:invitation]
        # Mesmo e-mail do convite de membro; o token só viaja no argumento do job.
        MemberInvitationMailer.invite(
          email_address: invitation.email, accept_url: CityDashboardUrl.invitation(Current.city, token: invitation.token)
        ).deliver_later
        render json: { id: invitation.id, email: invitation.email, role: invitation.role,
                       expires_at: invitation.expires_at.iso8601 }, status: :created
      end

      private

      def save(provider, status)
        result = Exams::SaveProvider.call(body_params.except("simulated"), provider: provider)
        return render_failure(result) if result.failure?

        render json: Exams::AdminJson.provider(result.payload[:provider].reload), status: status
      end

      def load_provider
        @provider = uuid?(params[:id]) && ExamProvider.find_by(id: params[:id])
        not_found unless @provider
      end
    end
  end
end
