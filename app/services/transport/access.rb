# Papéis do transporte (ADR 0048): a Membership ATIVA diz SE; o cadastro do
# motorista (TransportDriver ativo) diz QUEM é o motorista.
module Transport
  module Access
    module_function

    def dispatcher?(user) = user.present? && user.has_role?("transport_dispatcher")
    def committee?(user) = user.present? && user.has_role?("tfd_committee")

    # TransportDriver ATIVO do usuário com a Membership `driver` ativa; senão nil.
    def driver_for(user)
      return nil unless user.present? && user.has_role?("driver")

      TransportDriver.find_by(user_id: user.id, active: true)
    end
  end
end
