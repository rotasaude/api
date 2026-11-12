# Quem recebe os e-mails da ouvidoria (ADR 0051): membros ativos dos papéis
# pedidos cujo usuário não foi desativado. Só endereços; o e-mail nunca leva
# texto, protocolo, pessoa nem unidade.
module Ombudsman
  module Recipients
    module_function

    # -> [String], em ordem estável.
    def emails(roles)
      User.where(deactivated_at: nil)
          .where(id: Membership.active.where(role: Array(roles)).select(:user_id))
          .order(:email_address).pluck(:email_address)
    end
  end
end
