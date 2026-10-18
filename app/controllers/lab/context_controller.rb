# GET /lab/context (dashboard D1): laboratórios em que a sessão atua, de quais
# é liberadora e o conselho (CRF|CRBM|CRM ou null). B32: quem tem papel no
# laboratório (lab_staff, lab_releaser, municipal_admin ou UBS que coleta) e
# nenhum laboratório recebe 200 com `labs: []`; 403 só sem papel.
module Lab
  class ContextController < BaseController
    def show
      user = Current.user
      collects = Lab::Access.collecting_unit_ids(user).any?
      return forbid unless lab_role?(user) || collects

      ids = Lab::Access.provider_ids(user)
      # Admin ou UBS que coleta: todos os laboratórios ativos, somados aos do liberador.
      ids |= Lab::Access.labs.pluck(:id) if collects || Lab::Access.admin?(user)

      render json: { labs: Lab::Access.labs.where(id: ids).map { |p| { id: p.id, name: p.name } },
                     releaser_of: Lab::Access.releaser_provider_ids(user), council: Lab::Access.council(user),
                     technical_lead_of: Lab::Access.labs.select { |lab| Lab::Access.technical?(user, lab.id) }.map(&:id) }
    end

    private

    def lab_role?(user) = Lab::Access.staff?(user) || user.has_role?("lab_releaser") || Lab::Access.admin?(user)
  end
end
