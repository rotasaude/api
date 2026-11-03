# GET/POST/PATCH /transport/drivers[/:id] e GET /transport/driver_candidates
# (contrato §4, T3): motoristas ordenados pelo nome; a CNH nunca sai inteira.
module Transport
  class DriversController < BaseController
    include FleetResource

    # Usuários com a Membership `driver` ativa e sem cadastro de motorista
    # (candidatos ao POST), pelo nome; nada além de id e nome.
    def candidates
      users = User.where(deactivated_at: nil)
                  .where(id: Membership.active.where(role: "driver").select(:user_id))
                  .where.not(id: TransportDriver.select(:user_id))
                  .includes(:professional)
      items = users.map { |user| { user_id: user.id, name: Json.user_name(user) } }
      render json: { items: items.sort_by { |item| [ item[:name].to_s.downcase, item[:user_id] ] } }
    end

    private

    def resource_class = TransportDriver
    def command = SaveDriver
    def result_key = :driver
    def render_record(record) = Json.driver(record)

    def ordered(scope)
      scope.includes(user: :professional).sort_by { |driver| [ Json.user_name(driver.user).to_s.downcase, driver.id ] }
    end
  end
end
