module Maintenance
  module Mutations
    class InviteMaintainer < BaseMutation
      description "Convida um mantenedor. O token do convite NUNCA volta na resposta."

      argument :email_address, String, required: true
      # I2 (fix round 2): esta mutation APAGA senha, TOTP e sessões de quem já
      # existe. Sem step-up, ela era a primitiva de bloqueio da superfície:
      # uma sessão sequestrada (ou uma aba esquecida aberta) desligava qualquer
      # mantenedor de uma vez, e como esta fatia não tem mailer o convite
      # gerado não chega a ninguém — a conta ficaria irrecuperável pela API.
      argument :code, String, required: true, description: "TOTP do momento: convidar zera senha, TOTP e sessões"

      field :ok, Boolean, null: false
      field :errors, [ Types::UserErrorType ], null: false

      def resolve(email_address:, code:)
        email = email_address.to_s.strip.downcase

        audited(event: "maintenance.maintainer.invited", module_name: "maintainer") do
          raise Rejected.new("e-mail inválido", path: "emailAddress") unless email.match?(URI::MailTo::EMAIL_REGEXP)

          step_up!(code)

          invited = Maintainer.find_or_initialize_by(email_address: email)
          raise Rejected.new("mantenedor desativado", path: "emailAddress") if invited.persisted? && !invited.active?

          # I2: REconvidar quem já se matriculou não é convite, é recuperação —
          # e a recuperação zera a conta. Enquanto o link do convite não for
          # entregue por e-mail (não há mailer nesta fatia), o único caminho
          # que de fato entrega é `rake maintainer:invite`, rodado no servidor
          # por quem tem acesso a ele. Convidar um e-mail novo, ou reconvidar
          # quem nunca terminou a matrícula, continua valendo por aqui.
          if invited.persisted? && invited.enrolled?
            raise Rejected.new("mantenedor já matriculado: use `rake maintainer:invite` no servidor, " \
                               "que é o único caminho que entrega o link", path: "emailAddress")
          end

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
