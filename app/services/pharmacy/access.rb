# Papel da farmácia por local (ADR 0045, Desvio 2): vale com a Membership
# ATIVA do mesmo papel E o vínculo ATIVO em stock_location_staff do local.
# Revogar a Membership derruba o papel mesmo com o vínculo ainda ativo, e o
# vínculo revogado derruba mesmo com a Membership ativa (Review Focus 4).
# O vínculo diz ONDE; a Membership diz SE. Papéis fora da farmácia que o
# usuário tenha (health_professional, por exemplo) não entram aqui.
module Pharmacy
  module Access
    module_function

    # -> Set["pharmacist", ...] (vazio sem papel)
    def roles_at(user:, location:)
      linked = StockLocationStaff.active.where(user_id: user.id, stock_location_id: location.id).pluck(:role)
      return Set.new if linked.empty?

      Set.new(granted(user, linked))
    end

    # roles: lista (ou um papel) de Pharmacy::Catalog::ROLES.
    def allowed?(user:, location:, roles:)
      roles_at(user: user, location: location).intersect?(Set.new(Array(roles).map(&:to_s)))
    end

    # Almoxarife do local central ATIVO: lê a posição de todos os locais. Central
    # desativado não dá leitura global a ninguém.
    def central_keeper?(user)
      central_ids = StockLocation.active_locations.where(kind: "central").select(:id)
      linked = StockLocationStaff.active.where(user_id: user.id, role: "stock_keeper", stock_location_id: central_ids).exists?
      linked && granted(user, %w[stock_keeper]).any?
    end

    # Locais ativos onde o usuário tem algum papel; o almoxarife do central
    # vê todos os ativos. Ordem estável: nome, id.
    def locations_for(user)
      scope = StockLocation.active_locations.includes(:health_unit).order(:name, :id)
      return scope.to_a if central_keeper?(user)

      by_location = StockLocationStaff.active.where(user_id: user.id).pluck(:stock_location_id, :role)
      return [] if by_location.empty?

      roles = granted(user, by_location.map(&:last).uniq)
      ids = by_location.select { |_id, role| roles.include?(role) }.map(&:first).uniq
      scope.where(id: ids).to_a
    end

    # { location_id => Set["pharmacist", ...] } de TODOS os locais onde o usuário
    # tem papel válido, numa leva só (a mesma regra de roles_at). Quem não tem
    # papel nenhum recebe {}.
    def roles_by_location(user)
      by_location = StockLocationStaff.active.where(user_id: user.id).pluck(:stock_location_id, :role)
      return {} if by_location.empty?

      roles = granted(user, by_location.map(&:last).uniq)
      by_location.select { |_id, role| roles.include?(role) }
                 .group_by(&:first).transform_values { |pairs| Set.new(pairs.map(&:last)) }
    end

    # Dos papéis pedidos, os que o usuário tem como Membership ativa (a mesma
    # conta de User#has_role?, numa consulta só).
    def granted(user, roles)
      user.memberships.active.where(role: roles).pluck(:role)
    end
    private_class_method :granted
  end
end
