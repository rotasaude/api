# Situação do cadastro de quem tem o papel health_professional (spec §4.4):
# a tela Equipe e o painel de pendência dizem ao admin quem ainda não chama.
module Professionals
  module Status
    module_function

    def for_users(user_ids)
      ids = user_ids.map(&:to_s)
      with_profile = Professional.where(user_id: ids).pluck(:user_id).to_set
      linked = ProfessionalLink.active.joins(:professional).where(professionals: { user_id: ids })
                               .distinct.pluck("professionals.user_id").to_set
      ids.index_with do |id|
        next "missing_profile" unless with_profile.include?(id)

        linked.include?(id) ? "ok" : "missing_link"
      end
    end
  end
end
