# Permissões por laboratório compartilhadas pelas bases do CIQ/CEQ (Lab::Qc) e
# do estoque (Lab::Inventory) — D10. Inclua em controllers que herdam de
# Lab::BaseController (usa uuid?, not_found e forbid dele).
module Lab
  module ProviderScoped
    private

    def lab_param(key = :provider_id) = uuid?(params[key]) ? Lab::Access.labs.find_by(id: params[key]) : nil
    def reader?(provider_id) = Lab::Access.member?(Current.user, provider_id) || Lab::Access.admin?(Current.user)
    def configurer?(provider_id) = Lab::Access.admin?(Current.user) || Lab::Access.technical?(Current.user, provider_id)
    def technical?(provider_id) = Lab::Access.technical?(Current.user, provider_id)
    def releaser?(provider_id) = Lab::Access.releaser_link(Current.user, provider_id).present? || Lab::Access.admin?(Current.user)

    # before_action: @provider do parâmetro, com a permissão pedida.
    def provider!(key = :provider_id, allow: :reader?)
      @provider = lab_param(key)
      return not_found unless @provider

      forbid unless send(allow, @provider.id)
    end
  end
end
