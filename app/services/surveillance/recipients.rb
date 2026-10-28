# Quem recebe os alertas da vigilância por e-mail (módulo 25; ADR 0043):
# membros ativos do papel surveillance cujo usuário não foi desativado. Só
# endereços; o e-mail nunca leva dado do paciente.
module Surveillance
  module Recipients
    module_function

    # -> [String], em ordem estável.
    def emails
      User.where(deactivated_at: nil)
          .where(id: Membership.active.where(role: "surveillance").select(:user_id))
          .order(:email_address).pluck(:email_address)
    end
  end
end
