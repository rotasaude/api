module Maintenance
  module Mutations
    class InviteMaintainer < BaseMutation
      description "Convida (ou reconvida) um mantenedor. O token do convite NUNCA volta na resposta."

      argument :email_address, String, required: true

      field :ok, Boolean, null: false
      field :errors, [ Types::UserErrorType ], null: false

      def resolve(email_address:)
        email = email_address.to_s.strip.downcase

        audited(event: "maintenance.maintainer.invited", module_name: "maintainer") do
          raise Rejected.new("e-mail inválido", path: "emailAddress") unless email.match?(URI::MailTo::EMAIL_REGEXP)

          invited = Maintainer.find_or_initialize_by(email_address: email)
          raise Rejected.new("mantenedor desativado", path: "emailAddress") if invited.persisted? && !invited.active?

          PlatformRecord.transaction do
            invited.save!
            invited.update!(password: nil, otp_secret: nil, otp_enabled_at: nil, otp_recovery_codes: [],
                            failed_attempts: 0, locked_until: nil, invited_by_id: credential.maintainer.id)
            invited.maintainer_sessions.destroy_all
            MaintainerInvitation.invalidate_pending_for!(invited)
            MaintainerInvitation.issue!(maintainer: invited)
          end
        end
      end
    end
  end
end
