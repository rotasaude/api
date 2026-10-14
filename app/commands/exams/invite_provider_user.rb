# Convite do usuário do portal do prestador (contrato §5): o mecanismo de
# convite existente, papel exam_provider, ligado ao prestador.
module Exams
  module InviteProviderUser
    module_function

    def call(provider:, email:, invited_by:)
      InviteMember.call(email: email, role: "exam_provider", invited_by: invited_by, exam_provider: provider)
    end
  end
end
